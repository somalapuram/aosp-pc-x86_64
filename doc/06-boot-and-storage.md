# 06 — Boot and Storage

Getting from UEFI firmware to Android `init` on a real PC disk.

Android's normal boot flow assumes a fastboot-capable bootloader,
`boot.img`/`vbmeta` partitions, and AVB. A PC has UEFI and a GPT disk. This
document bridges that gap.

---

## 1. Boot chain

```
UEFI firmware
   └── ESP (FAT32, /EFI/BOOT/BOOTX64.EFI)
         └── GRUB2
               ├── bzImage        (kernel, from 03-kernel.md)
               ├── ramdisk.img    (Android first-stage init)
               └── cmdline
                     └── Android init
                           └── first_stage_mount → /system, /vendor
```

This is the Android-x86 approach and it remains the most practical for a PC.
You are deliberately bypassing `boot.img` and AVB during bring-up.

---

## 2. Partition layout

GPT, with **partition names matching the fstab `by-name` entries** from
[04-device-target.md](04-device-target.md):

| # | Name | Type | Size | Contents |
|---|---|---|---|---|
| 1 | `esp` | FAT32 | 512 MiB | GRUB, `bzImage`, `ramdisk.img` |
| 2 | `system` | ext4 | 6 GiB | `system.img` |
| 3 | `vendor` | ext4 | 2 GiB | `vendor.img` |
| 4 | `data` | ext4/f2fs | rest | userdata |

```bash
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart esp    fat32 1MiB    513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart system ext4  513MiB  6657MiB
parted -s "$DISK" mkpart vendor ext4  6657MiB 8705MiB
parted -s "$DISK" mkpart data   ext4  8705MiB 100%
```

`by-name` symlinks come from GPT partition labels via `ueventd`. Confirm they
appear under `/dev/block/by-name/` — if not, check
`ueventd.pc_x86_64.rc` and that `CONFIG_EFI_PARTITION=y` is set in the kernel.

---

## 3. GRUB configuration

```
set timeout=3
set default=0

menuentry "Android x86_64" {
    linux  /bzImage root=/dev/ram0 androidboot.hardware=pc_x86_64 \
           androidboot.selinux=permissive \
           console=ttyS0,115200 console=tty0 \
           loglevel=7
    initrd /ramdisk.img
}

menuentry "Android x86_64 (SwiftShader, verbose)" {
    linux  /bzImage root=/dev/ram0 androidboot.hardware=pc_x86_64 \
           androidboot.selinux=permissive \
           androidboot.hardware.gralloc=default \
           console=ttyS0,115200 console=tty0 \
           loglevel=8 ignore_loglevel initcall_debug
    initrd /ramdisk.img
}
```

### Critical cmdline parameters

| Parameter | Why |
|---|---|
| `androidboot.hardware=pc_x86_64` | Selects `fstab.pc_x86_64`, `init.pc_x86_64.rc`. Must match `PRODUCT_DEVICE`. |
| `androidboot.selinux=permissive` | **Bring-up only.** You will not boot with enforcing policy before writing vendor sepolicy. |
| `console=ttyS0,115200` | Serial console. The single most valuable debugging tool in this project. |
| `console=tty0` | Also to screen, once KMS is up. |

> ⚠️ `androidboot.selinux=permissive` must be removed before anything ships,
> and re-enabling enforcing will surface a large batch of denials at once.
> Consider flipping to enforcing early on a branch, just to size the work.

### Installing GRUB

```bash
sudo mount "$ESP" /mnt/esp
sudo grub-install --target=x86_64-efi --efi-directory=/mnt/esp \
     --bootloader-id=BOOT --removable --boot-directory=/mnt/esp/boot
sudo cp arch/x86/boot/bzImage /mnt/esp/
sudo cp $OUT/ramdisk.img /mnt/esp/
sudo cp grub.cfg /mnt/esp/boot/grub/
```

`--removable` writes `/EFI/BOOT/BOOTX64.EFI`, which UEFI will boot without an
NVRAM entry. Essential for USB-stick testing and for VMs with fresh NVRAM.

---

## 4. Writing images to disk

```bash
OUT=$REPO/android_17/out/target/product/pc_x86_64

sudo dd if=$OUT/system.img of=/dev/disk/by-partlabel/system bs=4M status=progress
sudo dd if=$OUT/vendor.img of=/dev/disk/by-partlabel/vendor bs=4M status=progress
sudo mkfs.ext4 -L data /dev/disk/by-partlabel/data
```

If `TARGET_USERIMAGES_SPARSE_EXT_DISABLED := false`, the images are Android
sparse format — convert first:

```bash
simg2img $OUT/system.img /tmp/system.raw
```

For the QEMU loop, script this against a loopback mount of `android-pc.img`
so a rebuild-and-boot cycle is one command.

---

## 5. Secure Boot

Turn it **off** on the test machine. Signing your own kernel and GRUB with
enrolled keys is a distraction during bring-up. Revisit only if the product
goal requires it.

---

## 6. Deferred: the things you turned off

These are all disabled in [04-device-target.md](04-device-target.md) for
bring-up. Each is real work to restore:

| Feature | Why deferred | Cost to restore |
|---|---|---|
| **AVB / verified boot** | Needs signed `vbmeta`, chain of trust from a bootloader you do not control | High — UEFI Secure Boot + AVB integration is genuinely hard on PC |
| **dm-verity** | Requires AVB metadata | Medium |
| **Dynamic partitions (`super.img`)** | Adds `liblp`, resize logic | Medium |
| **A/B updates** | Needs slot metadata, `dm-user` in kernel | High |
| **Recovery** | Separate ramdisk, UI | Medium |
| **OTA** | Depends on all of the above | High |

**If the goal is learning or kernel development, you may never need any of
them.** If the goal is a product, they are unavoidable and should be
scheduled explicitly rather than discovered late.

---

## 7. Debugging first boot

Serial console is not optional. In QEMU it is `-serial mon:stdio`. On metal,
use a USB-TTL adapter, or `netconsole`:

```
netconsole=6666@192.168.1.50/eth0,6666@192.168.1.1/
```

Useful early checks:

```bash
# did the kernel find the disk?
cat /proc/partitions

# did by-name symlinks appear?
ls -l /dev/block/by-name/

# what did first-stage init do?
dmesg | grep -i 'init\|first_stage\|selinux'
```

The most common first-boot failures, in order:
1. `by-name` symlinks missing → GPT labels or `CONFIG_EFI_PARTITION`
2. `androidboot.hardware` mismatch → wrong or missing fstab
3. ext4 feature mismatch → `mkfs.ext4` defaults newer than kernel support
4. SELinux denials → you forgot `permissive`
