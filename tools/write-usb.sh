#!/usr/bin/env bash
#
# Write the pc_x86_64 disk image to a USB stick (or any removable block device)
# so it can be booted on real hardware.
#
#   ./build.sh usb                 list candidate devices and exit
#   ./build.sh usb /dev/sdX        write the image to /dev/sdX
#   ./build.sh usb /dev/sdX --yes  skip the confirmation prompt
#
# This is destructive. Everything on the target device is erased. The script
# refuses anything that is not removable, anything holding a mounted
# filesystem, and anything that looks like the running system's disk, but the
# final responsibility for naming the right device is yours.
#
set -euo pipefail

X86_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${IMG:-$X86_ROOT/android-pc.img}"

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else R=''; G=''; Y=''; B=''; N=''; fi
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

TARGET="${1:-}"
ASSUME_YES=0
[[ "${2:-}" == "--yes" ]] && ASSUME_YES=1

# ------------------------------------------------------------- candidates ----
# Match on USB transport as well as the removable flag. USB *SSDs* -- Samsung
# T5/T7 and similar -- report removable=0 because they are not removable media
# in the kernel's sense, so keying only on RM hides exactly the devices people
# most often want to write.
list_candidates() {
    info "USB / removable block devices"
    local found=0
    while read -r name size tran rm model; do
        [[ "$tran" == "usb" || "$rm" == "1" ]] || continue
        local note=""
        [[ "$rm" != "1" ]] && note="  (fixed disk on USB -- check this is really the target)"
        printf '  /dev/%-8s %-9s %-6s %s%s\n' "$name" "$size" "${tran:-?}" "${model:-}" "$note"
        found=1
    done < <(lsblk -dno NAME,SIZE,TRAN,RM,MODEL 2>/dev/null)
    (( found )) || warn "none found -- plug the device in, or pass it explicitly"
    echo
    echo "Then:  ./build.sh usb /dev/sdX"
}

[[ -n "$TARGET" ]] || { list_candidates; exit 0; }

# ------------------------------------------------------------ safety net ----
[[ -b "$TARGET" ]] || die "not a block device: $TARGET"

# Whole device, not a partition -- GRUB and the GPT need the whole disk.
base=$(basename "$TARGET")
[[ -e "/sys/block/$base" ]] || die "$TARGET looks like a partition; pass the whole device (e.g. /dev/sdb, not /dev/sdb1)"

removable=$(cat "/sys/block/$base/removable" 2>/dev/null || echo 0)
tran=$(lsblk -dno TRAN "$TARGET" 2>/dev/null || true)
if [[ "$removable" != "1" && "$tran" != "usb" ]]; then
    die "$TARGET is neither removable nor USB-attached. Refusing -- this is how
     internal disks get destroyed. If you are certain, dd it by hand."
fi

# Refuse if anything on the device is mounted.
if lsblk -no MOUNTPOINT "$TARGET" 2>/dev/null | grep -q .; then
    lsblk -no NAME,MOUNTPOINT "$TARGET" | sed 's/^/     /' >&2
    die "$TARGET has mounted filesystems (above). Unmount them first."
fi

# Refuse the disk carrying the running root filesystem, belt and braces.
rootsrc=$(findmnt -no SOURCE / 2>/dev/null || true)
rootdisk=$(lsblk -no PKNAME "$rootsrc" 2>/dev/null | head -1 || true)
[[ -n "$rootdisk" && "$base" == "$rootdisk" ]] && die "$TARGET carries the running root filesystem"

[[ -f "$IMG" ]] || die "no image: $IMG  (run ./build.sh image)"

img_bytes=$(stat -c%s "$IMG")

# lsblk reads the size from sysfs and needs no privileges; blockdev opens the
# device and therefore requires root. Falling back to 0 on failure would be
# worse than useless -- it turns "cannot determine size" into "device is too
# small", which is what a bare `|| echo 0` used to do here.
dev_bytes=$(lsblk -bdno SIZE "$TARGET" 2>/dev/null | head -1)
if ! [[ "$dev_bytes" =~ ^[0-9]+$ ]]; then
    dev_bytes=$(sudo blockdev --getsize64 "$TARGET" 2>/dev/null || true)
fi
[[ "$dev_bytes" =~ ^[0-9]+$ && "$dev_bytes" -gt 0 ]] \
    || die "could not determine the size of $TARGET
     Neither 'lsblk -bdno SIZE' nor 'blockdev --getsize64' returned a size."

img_h=$(numfmt --to=iec "$img_bytes"); dev_h=$(numfmt --to=iec "$dev_bytes")

(( dev_bytes >= img_bytes )) || die "device too small: $dev_h < image $img_h
     Rebuild smaller, e.g.:  DISK_SIZE_MB=14336 ./build.sh image"

info "about to overwrite $TARGET"
printf '  device : %s  %s  %s\n' "$TARGET" "$dev_h" "$(lsblk -dno MODEL "$TARGET" 2>/dev/null || true)"
printf '  image  : %s  %s (%s on disk)\n' "$IMG" "$img_h" "$(du -h "$IMG" | cut -f1)"

# Show what is actually on the device. A large USB SSD is far more likely to
# hold something the owner cares about than a flash stick is, and the size
# mismatch alone should give pause.
echo
info "current contents of $TARGET"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$TARGET" 2>/dev/null | sed 's/^/  /'

if [[ "$removable" != "1" ]]; then
    echo
    warn "$TARGET is a FIXED disk on USB (e.g. a portable SSD), not a flash stick."
    warn "Those usually hold real data. Be certain this is the device you mean."
fi

echo
printf '  %sEVERYTHING ON %s WILL BE DESTROYED.%s\n' "$R" "$TARGET" "$N"
printf '  %sThe image is %s; the remaining %s will become unallocated.%s\n\n' \
       "$R" "$img_h" "$(numfmt --to=iec $((dev_bytes - img_bytes)))" "$N"

if (( ! ASSUME_YES )); then
    read -r -p "  Type the device path again to confirm: " confirm
    [[ "$confirm" == "$TARGET" ]] || die "confirmation did not match; nothing written"
fi

# ----------------------------------------------------------------- write ----
# conv=fsync so the exit status means the data actually reached the device;
# without it dd returns as soon as the page cache has it.
info "writing (this takes a while; the image is sparse but dd writes it whole)"
if [[ $EUID -ne 0 ]]; then
    sudo dd if="$IMG" of="$TARGET" bs=4M status=progress conv=fsync
else
    dd if="$IMG" of="$TARGET" bs=4M status=progress conv=fsync
fi

sync
ok "image written"

# The image's backup GPT sits at the end of the IMAGE, not the end of the
# DEVICE, so on a larger stick it lands in the wrong place. Most firmware
# boots anyway, but relocating it keeps partition tools happy.
if command -v sgdisk >/dev/null 2>&1; then
    info "relocating backup GPT to the end of the device"
    if [[ $EUID -ne 0 ]]; then sudo sgdisk -e "$TARGET" >/dev/null 2>&1 || warn "sgdisk -e failed (harmless)"
    else sgdisk -e "$TARGET" >/dev/null 2>&1 || warn "sgdisk -e failed (harmless)"; fi
fi
sync

echo
ok "done -- $TARGET is bootable"
cat <<'EOF'

  On the target machine:
    - Disable Secure Boot. The GRUB build here is unsigned.
    - Boot the USB device. It installs as /EFI/BOOT/BOOTX64.EFI (removable
      path), so firmware finds it without an NVRAM entry.
    - Prefer a machine with Intel or AMD graphics. NVIDIA has no Android
      driver and will not get past software rendering.

  If it does not boot, a serial console is the fastest way to find out why:
  the kernel command line already carries console=ttyS0,115200.
EOF
