#!/usr/bin/env bash
#
# Assemble a bootable GPT disk image for the pc_x86_64 target.
#
#   UEFI (OVMF) -> GRUB on the ESP -> bzImage + ramdisk.img -> Android init
#
# Deliberately rootless: no loop devices, no mounts, no sudo. mtools populates
# the FAT ESP in place and partition images are dd'd to computed GPT offsets.
# That keeps the edit/build/boot loop unprivileged and scriptable.
#
# See doc/06-boot-and-storage.md.
#
set -euo pipefail

X86_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_SRC="$X86_ROOT/linux"
AOSP_ROOT="$X86_ROOT/android_17"
PRODUCT_OUT="$AOSP_ROOT/out/target/product/pc_x86_64"
HOST_BIN="$AOSP_ROOT/out/host/linux-x86/bin"
WORK="$X86_ROOT/out/disk"
DISK="$X86_ROOT/android-pc.img"

# Sized to fit a nominal 16 GB USB stick, which is really ~14.9 GiB. A 32 GiB
# image does not fit a "32GB" stick either (~29.8 GiB usable), so a round
# power-of-two image is exactly the wrong choice for removable media.
# Raise it for a larger target: DISK_SIZE_MB=28672 ./build.sh image
DISK_SIZE_MB=${DISK_SIZE_MB:-14336}
ESP_MB=${ESP_MB:-512}
SYSTEM_MB=${SYSTEM_MB:-6144}
VENDOR_MB=${VENDOR_MB:-2048}
# /metadata holds aconfig flag storage, apex data and encryption metadata.
# Without it aconfigd cannot initialise and every feature flag lookup fails
# with ERROR_PACKAGE_NOT_FOUND, which crash-loops system_server:
#     aconfigd_system: failed to copy /system/etc/aconfig/package.map
#                      to /metadata/aconfig/...
#     selinux: Could not stat /metadata: No such file or directory
#     IllegalArgumentException: Invalid feature flag: android.security.*
METADATA_MB=${METADATA_MB:-64}

# Deterministic PARTUUID for the ESP.
#
# Android init only creates /dev/block/by-name/* symlinks for partitions on the
# *boot device* (devices.cpp:568, `if (info.is_boot_device)`). It learns which
# device that is from androidboot.boot_part_uuid: the PARTUUID of the partition
# holding the kernel, which for us is the ESP. init finds that partition and
# sets boot_devices to the block device containing it.
#
# The older androidboot.boot_devices= takes a sysfs path instead, which would
# hardcode QEMU's virtio-blk topology and break on real NVMe/AHCI hardware.
# The UUID approach is topology-independent, so it works in both.
ESP_PARTUUID=${ESP_PARTUUID:-9d4ae3f2-1e6b-4a58-8b3c-000000000001}

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else R=''; G=''; Y=''; B=''; N=''; fi
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

for t in sgdisk mformat mcopy mmd grub-mkstandalone mke2fs truncate dd; do
    command -v "$t" >/dev/null || die "missing tool: $t  (apt install gdisk mtools grub-efi-amd64-bin e2fsprogs)"
done

mkdir -p "$WORK"

# ---------------------------------------------------------------- inputs ----
BZIMAGE="$KERNEL_SRC/arch/x86/boot/bzImage"
[[ -f "$BZIMAGE" ]] || die "no kernel: $BZIMAGE  (run ./build.sh kernel)"

RAMDISK="$PRODUCT_OUT/ramdisk.img"
SYSTEM_IMG="$PRODUCT_OUT/system.img"
VENDOR_IMG="$PRODUCT_OUT/vendor.img"

missing=()
[[ -f "$RAMDISK"    ]] || missing+=("ramdisk.img")
[[ -f "$SYSTEM_IMG" ]] || missing+=("system.img")
[[ -f "$VENDOR_IMG" ]] || missing+=("vendor.img")
if (( ${#missing[@]} )); then
    die "missing AOSP images in $PRODUCT_OUT: ${missing[*]}
     run:  ANDROID_TARGET=pc_x86_64-trunk_staging-userdebug ./build.sh android"
fi

# AOSP ships ext4 images in Android sparse format; convert if needed.
unsparse() {
    local src=$1 dst=$2 simg2img
    simg2img=$(command -v simg2img || echo "$HOST_BIN/simg2img")
    if head -c4 "$src" | od -An -tx1 | grep -qi '3a ff 26 ed'; then
        [[ -x "$simg2img" ]] || die "sparse image but no simg2img (apt install android-sdk-libsparse-utils)"
        "$simg2img" "$src" "$dst"
    else
        cp --reflink=auto "$src" "$dst"
    fi
}

# ------------------------------------------------------------------ GRUB ----
info "building standalone GRUB EFI image"
# GRUB_DEFAULT=1 selects the verbose entry; KERNEL_EXTRA_ARGS appends to both.
cat > "$WORK/grub.cfg" <<EOF
set timeout=3
set default=${GRUB_DEFAULT:-0}

# The ESP carries a volume label so GRUB finds it regardless of disk ordering.
search --no-floppy --label ANDROIDESP --set=root

# Default entry keeps the kernel console quiet.
#
# ttyS0 is an emulated 16550: every byte is a port write and therefore a VM
# exit. At loglevel=7 a permissive-mode boot emits thousands of avc denials
# (enough to hit "audit: backlog limit exceeded"), and pushing all of that
# through the UART starves the guest badly enough to trip Android's watchdog:
#     Watchdog: *** WATCHDOG KILLING SYSTEM PROCESS:
#               Blocked in handler on main thread (main) for 67s
# with no actual deadlock -- the main thread stack shows ordinary
# ULocale/Configuration/Resources work.
#
# loglevel=4 keeps warnings and above on the console; everything else is still
# in the ring buffer via dmesg. Logcat comes over virtio-console regardless,
# which is cheap. Use the verbose entry (GRUB_DEFAULT=1) when debugging early
# boot, accepting that it distorts timing.
menuentry "Android pc_x86_64" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=permissive \\
           console=ttyS0,115200 loglevel=7
    initrd /ramdisk.img
}

menuentry "Android pc_x86_64 (verbose, serial only)" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=permissive \\
           console=ttyS0,115200 \\
           loglevel=8 ignore_loglevel printk.devkmsg=on \\
           androidboot.logcat_serial=1 \\
           androidboot.verifiedbootstate=orange ${KERNEL_EXTRA_ARGS:-}
    initrd /ramdisk.img
}
EOF

grub-mkstandalone -O x86_64-efi -o "$WORK/bootx64.efi" \
    --modules="part_gpt fat ext2 normal linux echo all_video test true sleep search search_label configfile gzio" \
    "boot/grub/grub.cfg=$WORK/grub.cfg" 2>/dev/null
ok "bootx64.efi $(du -h "$WORK/bootx64.efi" | cut -f1)"

# ------------------------------------------------------------------- ESP ----
info "building ESP (FAT32, ${ESP_MB} MiB)"
rm -f "$WORK/esp.img"
truncate -s "${ESP_MB}M" "$WORK/esp.img"
mformat -i "$WORK/esp.img" -F -v ANDROIDESP ::
mmd    -i "$WORK/esp.img" ::/EFI ::/EFI/BOOT
mcopy  -i "$WORK/esp.img" "$WORK/bootx64.efi" ::/EFI/BOOT/BOOTX64.EFI
mcopy  -i "$WORK/esp.img" "$BZIMAGE"          ::/bzImage
mcopy  -i "$WORK/esp.img" "$RAMDISK"          ::/ramdisk.img
ok "ESP populated: BOOTX64.EFI, bzImage, ramdisk.img"

# ------------------------------------------------------- partition images ----
info "preparing partition images"
unsparse "$SYSTEM_IMG" "$WORK/system.raw"
unsparse "$VENDOR_IMG" "$WORK/vendor.raw"
ok "system $(du -h "$WORK/system.raw" | cut -f1), vendor $(du -h "$WORK/vendor.raw" | cut -f1)"

rm -f "$WORK/metadata.raw"
truncate -s "${METADATA_MB}M" "$WORK/metadata.raw"
mke2fs -q -t ext4 -L metadata "$WORK/metadata.raw" >/dev/null 2>&1
ok "metadata ${METADATA_MB} MiB (empty ext4)"

USERDATA_MB=$(( DISK_SIZE_MB - ESP_MB - SYSTEM_MB - VENDOR_MB - METADATA_MB - 16 ))
rm -f "$WORK/userdata.raw"
truncate -s "${USERDATA_MB}M" "$WORK/userdata.raw"
mke2fs -q -t ext4 -L userdata "$WORK/userdata.raw" >/dev/null 2>&1
ok "userdata ${USERDATA_MB} MiB (empty ext4)"

# ------------------------------------------------------------------ disk ----
# Partition NAMES here are what become /dev/block/by-name/* via the kernel's
# EFI partition support -- they must match fstab.pc_x86_64.
info "creating GPT disk ${DISK_SIZE_MB} MiB"
rm -f "$DISK"
truncate -s "${DISK_SIZE_MB}M" "$DISK"

sgdisk -Z "$DISK" >/dev/null 2>&1 || true
sgdisk \
    -n 1:1MiB:+${ESP_MB}MiB    -t 1:ef00 -c 1:esp \
    -n 2:0:+${SYSTEM_MB}MiB    -t 2:8300 -c 2:system \
    -n 3:0:+${VENDOR_MB}MiB    -t 3:8300 -c 3:vendor \
    -n 4:0:+${METADATA_MB}MiB  -t 4:8300 -c 4:metadata \
    -n 5:0:0                   -t 5:8300 -c 5:userdata \
    -u 1:"$ESP_PARTUUID" \
    "$DISK" >/dev/null
ok "esp PARTUUID $ESP_PARTUUID (androidboot.boot_part_uuid)"

# Write each partition image at its GPT-assigned offset.
write_part() {
    local num=$1 src=$2 name=$3 start
    start=$(sgdisk -i "$num" "$DISK" | awk '/First sector/{print $3}')
    [[ -n "$start" ]] || die "could not read start sector of partition $num"
    dd if="$src" of="$DISK" bs=512 seek="$start" conv=notrunc,sparse status=none
    ok "$(printf '%-9s' "$name") -> sector $start"
}

info "writing partitions"
write_part 1 "$WORK/esp.img"      esp
write_part 2 "$WORK/system.raw"   system
write_part 3 "$WORK/vendor.raw"   vendor
write_part 4 "$WORK/metadata.raw" metadata
write_part 5 "$WORK/userdata.raw" userdata

echo
sgdisk -p "$DISK" | tail -6
echo
ok "disk ready: $DISK ($(du -h --apparent-size "$DISK" | cut -f1) apparent, $(du -h "$DISK" | cut -f1) on disk)"
echo "    boot it with:  ./build.sh run"
