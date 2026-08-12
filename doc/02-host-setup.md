# 02 — Host and Development VM Setup

Your build host: 192 cores, 246 GB RAM, 3.2 TB free on `/home`, `/dev/kvm`
present. This is an excellent AOSP machine — a clean `aosp_cf_x86_64_phone`
build should land in roughly 30–45 minutes.

---

## 1. Host packages

AOSP ships its own clang, ninja and Soong, so system `clang`/`cmake`/`ninja`
are irrelevant. What you do need:

```bash
sudo apt-get install -y \
  git-core gnupg flex bison build-essential zip curl zlib1g-dev \
  libc6-dev-i386 x11proto-dev libx11-dev lib32z1-dev libgl1-mesa-dev \
  libxml2-utils xsltproc unzip fontconfig rsync ccache
```

For the kernel build and disk-image work:

```bash
sudo apt-get install -y \
  libelf-dev libssl-dev bc dwarves \
  qemu-system-x86 qemu-utils ovmf \
  grub-efi-amd64-bin grub-common dosfstools mtools parted
```

`qemu-system-x86_64`, `VBoxManage`, `docker`, `ninja`, `cmake` and `clang` were
all absent at audit time. Only the QEMU/OVMF/GRUB set above actually matters.

---

## 2. First build — the Cuttlefish reference

Build this **before** writing any device code. It validates your toolchain and
gives you the reference implementation to read and diff against.

```bash
cd ~/amar/x86/android_17
source build/envsetup.sh
lunch aosp_cf_x86_64_phone-trunk_staging-userdebug
m -j192
```

Keep the output tree. You will diff your device's `vendor/` against
Cuttlefish's constantly.

### ccache

Soong benefits little from ccache, but the kernel builds benefit a lot:

```bash
export USE_CCACHE=1
export CCACHE_DIR=~/amar/x86/.ccache
ccache -M 200G
```

---

## 3. The development VM — QEMU/KVM as a *generic PC*

This is the key distinction from Cuttlefish. You are **not** using
`launch_cvd` or crosvm. You are booting your Android images the way a physical
PC boots them: UEFI firmware → GRUB → kernel → GPT disk → DRM/KMS.

### 3.1 Create the disk

```bash
cd ~/amar/x86
qemu-img create -f raw android-pc.img 32G

# GPT with an ESP + system + vendor + userdata
parted -s android-pc.img mklabel gpt
parted -s android-pc.img mkpart ESP    fat32 1MiB   513MiB
parted -s android-pc.img set 1 esp on
parted -s android-pc.img mkpart system ext4  513MiB 6657MiB
parted -s android-pc.img mkpart vendor ext4  6657MiB 8705MiB
parted -s android-pc.img mkpart data   ext4  8705MiB 100%
```

Partition sizes are a starting point; see [06-boot-and-storage.md](06-boot-and-storage.md).

### 3.2 Copy the UEFI firmware

OVMF vars must be writable per-VM:

```bash
cp /usr/share/OVMF/OVMF_CODE.fd  ~/amar/x86/OVMF_CODE.fd
cp /usr/share/OVMF/OVMF_VARS.fd  ~/amar/x86/OVMF_VARS.fd
```

### 3.3 Launch

```bash
qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -smp 8 -m 8G \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=$HOME/amar/x86/OVMF_CODE.fd \
  -drive if=pflash,format=raw,unit=1,file=$HOME/amar/x86/OVMF_VARS.fd \
  -drive file=$HOME/amar/x86/android-pc.img,format=raw,if=none,id=disk0 \
  -device virtio-blk-pci,drive=disk0 \
  -device virtio-vga-gl -display gtk,gl=on \
  -device intel-hda -device hda-duplex \
  -device virtio-net-pci,netdev=n0 \
  -netdev user,id=n0,hostfwd=tcp::5555-:5555 \
  -device qemu-xhci -device usb-tablet -device usb-kbd \
  -serial mon:stdio
```

Then `adb connect localhost:5555`.

### 3.4 Why each flag matters

| Flag | Why |
|---|---|
| `-machine q35` | Modern PCIe chipset, not the ancient i440fx. Matches real hardware. |
| `pflash` OVMF | Real UEFI. Exercises the true ESP + GRUB boot path. |
| `virtio-vga-gl` | Presents a genuine DRM/KMS node at `/dev/dri/card0`. Same interface `i915`/`amdgpu` expose. |
| `intel-hda` | Real ALSA device — exercises the actual audio HAL path, not virtio-snd. |
| `usb-tablet`/`usb-kbd` | Real evdev input, not virtio-input. |
| `virtio-blk` | Fast. Swap for `-device ahci` if you want to exercise SATA discovery. |

This covers roughly 90% of a physical PC boot. What it **cannot** tell you:
real i915/amdgpu behaviour, WiFi firmware loading, ACPI quirks, lid/suspend,
and thermal. Those need metal — see §5.

### 3.5 GPU passthrough (VFIO) — closing the last 10%

If your dev box has a spare GPU, pass it through and you get real `i915` or
`amdgpu` in the VM:

```bash
# bind the device to vfio-pci, then:
  -device vfio-pci,host=0000:03:00.0,multifunction=on
```

⚠️ Your host has an NVIDIA GPU (`~/.nvidia-settings-rc`). **NVIDIA is not a
viable Android target** — there is no proprietary NVIDIA Android driver for
PC, and NVK/nouveau is not ready for a display stack. For passthrough
testing you want a spare Intel Arc / AMD card, or an Intel iGPU you can
dedicate.

---

## 4. VirtualBox — secondary only

VirtualBox does emulate a plain PC, so it is more defensible here than it was
for Cuttlefish. But:

- Weak DRM/KMS support (VBoxSVGA / vmwgfx) — poor for graphics work
- No VFIO passthrough
- Slower than KVM

**Use it as an occasional "does it boot under different firmware and a
different device set" smoke test.** Not as your primary loop.

---

## 5. Bare-metal test target

Keep one physical machine available from Phase 3 onward. Requirements:

- **Intel iGPU (Gen9+, i.e. Skylake or newer) or AMD (GCN/RDNA)** — see the
  NVIDIA warning above
- UEFI firmware with Secure Boot switchable off
- A spare NVMe/SATA disk, or boot from USB
- Serial console if possible (USB-TTL adapter); otherwise `netconsole` over
  Ethernet. Early-boot debugging without a console is painful.

An Intel NUC or a mainstream business laptop is ideal — well-documented ACPI,
mature `i915`, no exotic firmware.

---

## 6. Group membership

```bash
sudo usermod -aG kvm,render,video $USER
# log out and back in
```

`render` and `video` matter once you start doing DRM work on the host.
