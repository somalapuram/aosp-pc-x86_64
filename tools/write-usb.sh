#!/usr/bin/env bash
# Write the built image to a USB device.
#
#   ./build.sh usb                      list candidate devices
#   ./build.sh usb /dev/sdX [--yes]     KEEP DATA (default): rewrite esp, system and
#                                       vendor in place; metadata and userdata --
#                                       Wi-Fi, developer options, wireless debugging,
#                                       installed apps -- survive.
#   ./build.sh usb /dev/sdX --wipe-data full image write; everything on the device
#                                       is replaced, userdata comes up empty.
#   ./build.sh usb /dev/sdX --dry-run   show what would happen, write nothing.
#
# Why keep-data is the default: every write used to wipe userdata, and every
# boot after a write started with setting up Wi-Fi, enabling developer options
# and wireless debugging again. The image build only ever changes esp, system
# and vendor; metadata and userdata are runtime state. Writing the three
# partitions in place is what an OTA does, and the layout makes it safe:
#
#   - Partitions are found by NAME (fstab uses /dev/block/by-name/...), so the
#     device's own GPT stays and its partition GUIDs do not matter...
#   - ...except the ESP's, which grub.cfg in the NEW image names in
#     androidboot.boot_part_uuid. mkdisk.sh gives the ESP a fixed GUID, and this
#     script refuses a keep-data write if the device's ESP GUID differs.
#   - Each of esp/system/vendor on the device must be at least as large as in
#     the image; the filesystem inside is sized to the image's partition, so a
#     larger device partition is fine and a smaller one is refused.
#   - fstab has no fileencryption/keydirectory, so nothing in metadata is a
#     key for userdata; both are simply left alone.
#
# A device with no Android layout at all (a fresh stick) gets a full write --
# there is nothing to keep. A device WITH an Android layout that does not match
# is refused rather than guessed at; --wipe-data is the explicit way through.
# If a keep-data boot ever misbehaves (a userdata-dependent change in the new
# build), --wipe-data is the reset.
set -euo pipefail

X86_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${IMG:-$X86_ROOT/android-pc.img}"

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else R=''; G=''; Y=''; B=''; N=''; fi
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

TARGET=""; ASSUME_YES=0; MODE=keep; DRY_RUN=0
for a in "$@"; do
    case "$a" in
        --yes)                 ASSUME_YES=1 ;;
        --wipe-data|--wipe)    MODE=wipe ;;
        --keep-data|--keep)    MODE=keep ;;
        --dry-run)             DRY_RUN=1 ;;
        -*)                    die "unknown option: $a" ;;
        *) [[ -z "$TARGET" ]] && TARGET="$a" || die "unexpected argument: $a" ;;
    esac
done

SUDO=""; [[ $EUID -ne 0 ]] && SUDO=sudo

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
    echo "Then:  ./build.sh usb /dev/sdX            (keeps userdata)"
    echo "       ./build.sh usb /dev/sdX --wipe-data (full write)"
}

[[ -n "$TARGET" ]] || { list_candidates; exit 0; }
[[ -b "$TARGET" ]] || die "not a block device: $TARGET"
base=$(basename "$TARGET")
[[ -e "/sys/block/$base" ]] || die "$TARGET looks like a partition; pass the whole device (e.g. /dev/sdb, not /dev/sdb1)"

# Only removable or USB-attached devices, ever. Loop devices are the one
# exception: they are file-backed and exist here only so this script can be
# tested against a scratch image without a real stick.
removable=$(cat "/sys/block/$base/removable" 2>/dev/null || echo 0)
tran=$(lsblk -dno TRAN "$TARGET" 2>/dev/null || true)
devtype=$(lsblk -dno TYPE "$TARGET" 2>/dev/null || true)
if [[ "$devtype" != "loop" && "$removable" != "1" && "$tran" != "usb" ]]; then
    die "$TARGET is neither removable nor USB-attached. Refusing -- this is how
     internal disks get destroyed. If you are certain, dd it by hand."
fi
if lsblk -no MOUNTPOINT "$TARGET" 2>/dev/null | grep -q .; then
    lsblk -no NAME,MOUNTPOINT "$TARGET" | sed 's/^/     /' >&2
    die "$TARGET has mounted filesystems (above). Unmount them first."
fi
rootsrc=$(findmnt -no SOURCE / 2>/dev/null || true)
rootdisk=$(lsblk -no PKNAME "$rootsrc" 2>/dev/null | head -1 || true)
[[ -n "$rootdisk" && "$base" == "$rootdisk" ]] && die "$TARGET carries the running root filesystem"

[[ -f "$IMG" ]] || die "no image: $IMG  (run ./build.sh image)"
img_bytes=$(stat -c%s "$IMG")
dev_bytes=$(lsblk -bdno SIZE "$TARGET" 2>/dev/null | head -1)
if ! [[ "$dev_bytes" =~ ^[0-9]+$ ]]; then
    dev_bytes=$($SUDO blockdev --getsize64 "$TARGET" 2>/dev/null || true)
fi
[[ "$dev_bytes" =~ ^[0-9]+$ && "$dev_bytes" -gt 0 ]] \
    || die "could not determine the size of $TARGET
     Neither 'lsblk -bdno SIZE' nor 'blockdev --getsize64' returned a size."
img_h=$(numfmt --to=iec "$img_bytes"); dev_h=$(numfmt --to=iec "$dev_bytes")
(( dev_bytes >= img_bytes )) || die "device too small: $dev_h < image $img_h
     Rebuild smaller, e.g.:  DISK_SIZE_MB=14336 ./build.sh image"

DD=dd
command -v gnudd >/dev/null 2>&1 && DD=gnudd

# ---------------------------------------------------------------- layout ----
# part_info <disk-or-image> <n>  ->  "start_sector size_sectors guid name"
# sgdisk reads image files as readily as devices; the device needs root.
part_info() {
    local out
    if [[ -b "$1" ]]; then out=$($SUDO sgdisk -i "$2" "$1" 2>/dev/null) || return 1
    else out=$(sgdisk -i "$2" "$1" 2>/dev/null) || return 1; fi
    local start end guid name
    start=$(awk '/^First sector:/{print $3}' <<<"$out")
    end=$(awk '/^Last sector:/{print $3}' <<<"$out")
    guid=$(awk '/^Partition unique GUID:/{print tolower($4)}' <<<"$out")
    name=$(sed -n "s/^Partition name: '\(.*\)'$/\1/p" <<<"$out")
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && -n "$name" ]] || return 1
    echo "$start $((end - start + 1)) $guid $name"
}

# The layout mkdisk.sh produces, by partition number. Only 1-3 are rewritten.
declare -a NAMES=("" esp system vendor metadata userdata)

# Returns: "fresh" (no Android layout on the device), "match", or a reason.
check_layout() {
    local n names_seen=0
    for n in 1 2 3 4 5; do
        if part_info "$TARGET" "$n" >/dev/null 2>&1; then
            read -r _ _ _ dname <<<"$(part_info "$TARGET" "$n")"
            [[ "$dname" == "${NAMES[$n]}" ]] && names_seen=$((names_seen + 1))
        fi
    done
    (( names_seen == 0 )) && { echo fresh; return; }
    (( names_seen == 5 )) || { echo "device has only $names_seen of the 5 Android partitions by name"; return; }
    for n in 1 2 3 4 5; do
        read -r is isz iguid iname <<<"$(part_info "$IMG" "$n")" \
            || { echo "cannot read partition $n of the image"; return; }
        read -r ds dsz dguid dname <<<"$(part_info "$TARGET" "$n")"
        [[ "$iname" == "$dname" && "$iname" == "${NAMES[$n]}" ]] \
            || { echo "partition $n is '$dname' on the device, '$iname' in the image"; return; }
        if (( n <= 3 )) && (( dsz < isz )); then
            echo "partition $n ($iname) is $((dsz / 2048)) MiB on the device, $((isz / 2048)) MiB in the image"; return
        fi
        if (( n == 1 )) && [[ "$iguid" != "$dguid" ]]; then
            echo "ESP GUID differs: device $dguid, image $iguid -- the new grub.cfg would name a partition this disk does not have"; return
        fi
    done
    echo match
}

write_part_in_place() {
    local n=$1 is isz _ ds
    read -r is isz _ _ <<<"$(part_info "$IMG" "$n")"
    read -r ds _ _ _ <<<"$(part_info "$TARGET" "$n")"
    local bytes=$((isz * 512))
    info "${NAMES[$n]}: $(numfmt --to=iec "$bytes") -> $TARGET partition $n (sector $ds)"
    if (( DRY_RUN )); then
        echo "  would: $DD if=$IMG of=$TARGET bs=4M skip=$((is * 512)) seek=$((ds * 512)) count=$bytes (bytes)"
        return
    fi
    $SUDO "$DD" if="$IMG" of="$TARGET" bs=4M \
        iflag=skip_bytes,count_bytes oflag=seek_bytes \
        skip=$((is * 512)) seek=$((ds * 512)) count="$bytes" \
        status=progress conv=fsync,notrunc
}

if [[ "$MODE" == keep ]]; then
    command -v sgdisk >/dev/null 2>&1 || die "sgdisk is required for a keep-data write (apt-get install gdisk), or pass --wipe-data"
    verdict=$(check_layout)
    case "$verdict" in
        match) ;;
        fresh) info "$TARGET has no Android layout -- nothing to keep, doing a full write"; MODE=wipe ;;
        *)     die "cannot keep userdata on $TARGET: $verdict
     Pass --wipe-data for a full write (everything on the device is replaced)." ;;
    esac
fi

# --------------------------------------------------------------- confirm ----
info "target $TARGET"
printf '  device : %s  %s  %s\n' "$TARGET" "$dev_h" "$(lsblk -dno MODEL "$TARGET" 2>/dev/null || true)"
printf '  image  : %s  %s (%s on disk)\n' "$IMG" "$img_h" "$(du -h "$IMG" | cut -f1)"
echo
info "current contents of $TARGET"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$TARGET" 2>/dev/null | sed 's/^/  /'
if [[ "$removable" != "1" && "$devtype" != "loop" ]]; then
    echo
    warn "$TARGET is a FIXED disk on USB (e.g. a portable SSD), not a flash stick."
    warn "Those usually hold real data. Be certain this is the device you mean."
fi
echo
if [[ "$MODE" == keep ]]; then
    printf '  %sesp, system and vendor on %s will be overwritten in place.%s\n' "$Y" "$TARGET" "$N"
    printf '  %smetadata and userdata are KEPT (Wi-Fi, developer options, apps).%s\n\n' "$G" "$N"
else
    printf '  %sEVERYTHING ON %s WILL BE DESTROYED.%s\n' "$R" "$TARGET" "$N"
    printf '  %sThe image is %s; the remaining %s will become unallocated.%s\n\n' \
           "$R" "$img_h" "$(numfmt --to=iec $((dev_bytes - img_bytes)))" "$N"
fi
if (( DRY_RUN )); then
    info "dry run: mode=$MODE, nothing will be written"
elif (( ! ASSUME_YES )); then
    read -r -p "  Type the device path again to confirm: " confirm
    [[ "$confirm" == "$TARGET" ]] || die "confirmation did not match; nothing written"
fi

# ----------------------------------------------------------------- write ----
if [[ "$MODE" == keep ]]; then
    info "keep-data write with $DD: esp, system, vendor in place; GPT, metadata, userdata untouched"
    write_part_in_place 1
    write_part_in_place 2
    write_part_in_place 3
    (( DRY_RUN )) && { ok "dry run complete"; exit 0; }
    sync
    ok "esp, system and vendor written; userdata kept"
else
    info "full write with $DD (the image is sparse but dd writes it whole)"
    if (( DRY_RUN )); then
        echo "  would: $DD if=$IMG of=$TARGET bs=4M conv=fsync oflag=direct; sgdisk -e $TARGET"
        ok "dry run complete"; exit 0
    fi
    $SUDO "$DD" if="$IMG" of="$TARGET" bs=4M status=progress conv=fsync oflag=direct
    sync
    ok "image written"
    if command -v sgdisk >/dev/null 2>&1; then
        info "relocating backup GPT to the end of the device"
        $SUDO sgdisk -e "$TARGET" >/dev/null 2>&1 || warn "sgdisk -e failed (harmless)"
    fi
    sync
fi
echo
ok "done -- $TARGET is bootable"
cat <<'EOT'
  On the target machine:
    - Disable Secure Boot. The GRUB build here is unsigned.
    - Boot the USB device. It installs as /EFI/BOOT/BOOTX64.EFI (removable
      path), so firmware finds it without an NVRAM entry.
    - Intel (iris), AMD (radeonsi) and NVIDIA (nouveau) all have a driver in
      the image, and the GPU firmware for all three rides along in a second
      initramfs, so no vendor needs a build of its own.
  If it does not boot, pick "verbose, on screen" from the GRUB menu -- the
  default entry is deliberately quiet and shows nothing on the way up.
EOT
