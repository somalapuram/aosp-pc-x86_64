#!/system/bin/sh
#
# pc_install -- copy this running image onto the machine's internal disk.
#
# This is the piece that turns a bootable USB stick into an installed system,
# and it is the same shape as any distro installer: partition the target, copy
# the read-only partitions across verbatim, then give userdata everything that
# is left.
#
# IT ERASES THE TARGET DISK COMPLETELY. Three things gate that, and none of
# them is a formality:
#
#   1. It refuses to do anything unless ro.boot.pc_install is 1, which is set
#      only by the "Install" entry in the GRUB menu. Booting normally can never
#      reach this code.
#   2. It refuses to touch the disk it booted from, identified by PARTUUID
#      rather than by device name, because device names are assigned in probe
#      order and are not stable between boots.
#   3. It prints the target's size and current partition table and waits for
#      the word ERASE to be typed. No timeout, no default.
#
# WHY THE TARGET ESP GETS A NEW PARTUUID. The kernel command line carries
# androidboot.boot_part_uuid, and that is how the booted system finds its own
# boot partition. mkdisk.sh writes a fixed UUID, so a straight copy would leave
# the USB stick and the internal disk claiming the same one -- and with both
# attached, which is exactly the situation during and right after an install,
# nothing could tell them apart. The installed copy therefore gets its own
# UUID and a grub.cfg that names it.

set -u

LOG=/dev/kmsg
say() { echo "pc_install: $*" > "$LOG"; echo "pc_install: $*"; }
die() { echo "pc_install: FAILED: $*" > "$LOG"; echo; echo "  FAILED: $*"; echo; exit 1; }

# The layout mirrors tools/mkdisk.sh exactly. If that file changes, this must
# change with it -- the installed system is meant to be indistinguishable from
# a freshly written stick apart from userdata's size.
ESP_MB=512
METADATA_MB=64
TARGET_ESP_PARTUUID=9d4ae3f2-1e6b-4a58-8b3c-000000000002

# ---------------------------------------------------------------- gate ----
[ "$(getprop ro.boot.pc_install)" = "1" ] || {
    say "not install mode, doing nothing"
    exit 0
}

echo
echo "==============================================================="
echo "  Install Android to this machine's internal disk"
echo "==============================================================="
echo

# ------------------------------------------------------- find the source ----
# Identified by PARTUUID, never by name. sda/nvme0n1 ordering depends on probe
# order and USB enumeration timing, and getting this backwards would erase the
# stick the installer is running from.
SRC_UUID=$(getprop ro.boot.boot_part_uuid)
[ -n "$SRC_UUID" ] || die "no ro.boot.boot_part_uuid on the command line"

SRC_PART=""
for d in /dev/block/sd? /dev/block/sd?? /dev/block/nvme*n*p* /dev/block/mmcblk*p*; do
    [ -b "$d" ] || continue
    u=$(blkid -o value -s PARTUUID "$d" 2>/dev/null)
    [ "$u" = "$SRC_UUID" ] && { SRC_PART="$d"; break; }
done
[ -n "$SRC_PART" ] || die "cannot find the partition we booted from ($SRC_UUID)"

# strip the partition suffix: sda1 -> sda, nvme0n1p1 -> nvme0n1
case "$SRC_PART" in
    *nvme*|*mmcblk*) SRC_DISK=$(echo "$SRC_PART" | sed 's/p[0-9]*$//') ;;
    *)               SRC_DISK=$(echo "$SRC_PART" | sed 's/[0-9]*$//') ;;
esac
SRC_NAME=$(basename "$SRC_DISK")
say "booted from $SRC_NAME (esp $SRC_PART)"

# ------------------------------------------------------- find the target ----
# Every whole disk that is not the source and not removable. Removable is the
# important half: without it a second USB stick is a candidate, and the whole
# point of this script is that it picks the machine's own disk.
CANDIDATES=""
for s in /sys/block/*; do
    n=$(basename "$s")
    case "$n" in loop*|ram*|zram*|dm-*|sr*|md*) continue ;; esac
    [ "$n" = "$SRC_NAME" ] && continue
    [ -b "/dev/block/$n" ] || continue
    [ "$(cat "$s/removable" 2>/dev/null)" = "1" ] && continue
    CANDIDATES="$CANDIDATES $n"
done

# An explicit choice always wins, for the machine with two internal disks.
FORCED=$(getprop ro.boot.pc_install_target)
if [ -n "$FORCED" ]; then
    [ -b "/dev/block/$FORCED" ] || die "pc_install_target=$FORCED is not a block device"
    TGT_NAME="$FORCED"
    say "target forced by command line: $TGT_NAME"
else
    set -- $CANDIDATES
    [ $# -gt 0 ] || die "no internal disk found (only the boot device is present)"
    [ $# -eq 1 ] || die "found $# internal disks:$CANDIDATES
         Refusing to choose. Add androidboot.pc_install_target=<name> to the
         GRUB entry to name the one you mean."
    TGT_NAME="$1"
fi

TGT_DISK="/dev/block/$TGT_NAME"
[ "$TGT_DISK" = "$SRC_DISK" ] && die "target and source are the same disk"

TGT_BYTES=$(blockdev --getsize64 "$TGT_DISK" 2>/dev/null) || die "cannot size $TGT_DISK"
TGT_MB=$(( TGT_BYTES / 1024 / 1024 ))

# ----------------------------------------------------------- size check ----
src_part_mb() {
    b=$(blockdev --getsize64 "$1" 2>/dev/null) || echo 0
    echo $(( b / 1024 / 1024 ))
}
SYSTEM_MB=$(src_part_mb "${SRC_DISK}$( [ -b "${SRC_DISK}p2" ] && echo p2 || echo 2 )")
VENDOR_MB=$(src_part_mb "${SRC_DISK}$( [ -b "${SRC_DISK}p3" ] && echo p3 || echo 3 )")
[ "$SYSTEM_MB" -gt 0 ] || die "cannot read the source system partition"
[ "$VENDOR_MB" -gt 0 ] || die "cannot read the source vendor partition"

FIXED_MB=$(( ESP_MB + SYSTEM_MB + VENDOR_MB + METADATA_MB + 16 ))
DATA_MB=$(( TGT_MB - FIXED_MB ))
[ "$DATA_MB" -ge 2048 ] || die "$TGT_NAME is ${TGT_MB} MiB; needs at least $(( FIXED_MB + 2048 ))"

# -------------------------------------------------------------- confirm ----
echo "  Source (this USB device)   $SRC_NAME"
echo "  Target (will be ERASED)    $TGT_NAME   ${TGT_MB} MiB"
echo
echo "  Current contents of $TGT_NAME:"
sgdisk -p "$TGT_DISK" 2>/dev/null | sed -n '/Number/,$p' | sed 's/^/    /' || echo "    (no partition table)"
echo
echo "  After install:"
echo "    esp        ${ESP_MB} MiB"
echo "    system     ${SYSTEM_MB} MiB"
echo "    vendor     ${VENDOR_MB} MiB"
echo "    metadata   ${METADATA_MB} MiB"
echo "    userdata   ${DATA_MB} MiB      <- all remaining space"
echo
echo "  EVERYTHING ON $TGT_NAME WILL BE DESTROYED, including any other"
echo "  operating system installed on it."
echo
printf "  Type ERASE to continue, anything else to abort: "
read ANSWER
[ "$ANSWER" = "ERASE" ] || { echo; echo "  Aborted. Nothing was written."; echo; exit 0; }
echo

# ------------------------------------------------------------ partition ----
say "partitioning $TGT_NAME"
sgdisk -Z "$TGT_DISK" >/dev/null 2>&1 || true
sgdisk \
    -n 1:1MiB:+${ESP_MB}MiB     -t 1:ef00 -c 1:esp \
    -n 2:0:+${SYSTEM_MB}MiB     -t 2:8300 -c 2:system \
    -n 3:0:+${VENDOR_MB}MiB     -t 3:8300 -c 3:vendor \
    -n 4:0:+${METADATA_MB}MiB   -t 4:8300 -c 4:metadata \
    -n 5:0:0                    -t 5:8300 -c 5:userdata \
    -u 1:"$TARGET_ESP_PARTUUID" \
    "$TGT_DISK" >/dev/null || die "sgdisk failed on $TGT_DISK"
blockdev --rereadpt "$TGT_DISK" 2>/dev/null || true
sleep 2

# nvme and mmc insert a 'p' before the partition number; sd does not.
case "$TGT_NAME" in nvme*|mmcblk*) P="p" ;; *) P="" ;; esac
tp() { echo "${TGT_DISK}${P}$1"; }
sp() { case "$SRC_NAME" in nvme*|mmcblk*) echo "${SRC_DISK}p$1" ;; *) echo "${SRC_DISK}$1" ;; esac; }

for n in 1 2 3 4 5; do
    [ -b "$(tp $n)" ] || die "$(tp $n) did not appear after partitioning"
done

# ----------------------------------------------------------------- copy ----
# Straight block copies. system and vendor are read-only images and any
# filesystem-level copy would have to reproduce their SELinux labels exactly;
# dd sidesteps that question entirely.
copy() {
    say "copying $3"
    dd if="$1" of="$2" bs=4M conv=fsync 2>/dev/null || die "copying $3 failed"
}
copy "$(sp 1)" "$(tp 1)" "esp (${ESP_MB} MiB)"
copy "$(sp 2)" "$(tp 2)" "system (${SYSTEM_MB} MiB)"
copy "$(sp 3)" "$(tp 3)" "vendor (${VENDOR_MB} MiB)"
copy "$(sp 4)" "$(tp 4)" "metadata (${METADATA_MB} MiB)"

# userdata is made here rather than copied: the source one is a fixed 5.4 GiB
# and the whole point is that the installed system gets the rest of the disk.
say "creating userdata (${DATA_MB} MiB)"
mke2fs -t ext4 -q -F -L userdata "$(tp 5)" >/dev/null 2>&1 \
    || die "could not create the userdata filesystem"

# ------------------------------------------------------- fix up the ESP ----
# The copied grub.cfg still names the source ESP's PARTUUID, so an installed
# system would look for its boot partition on the USB stick. Point it at itself.
say "pointing the installed bootloader at the internal disk"
MNT=/mnt/pc_install_esp
mkdir -p "$MNT"
umount "$MNT" 2>/dev/null
mount -t vfat "$(tp 1)" "$MNT" || die "cannot mount the new ESP"

[ -f "$MNT/grub.cfg" ] || { umount "$MNT"; die "no grub.cfg on the copied ESP"; }

# Rewrite the boot UUID, and drop the Install entry from the installed copy --
# an installed system offering to install itself over its own disk is a trap.
sed -e "s/$SRC_UUID/$TARGET_ESP_PARTUUID/g" \
    -e '/^menuentry "Install Android/,/^}/d' \
    "$MNT/grub.cfg" > "$MNT/grub.cfg.new" || { umount "$MNT"; die "rewrite failed"; }
mv "$MNT/grub.cfg.new" "$MNT/grub.cfg" || { umount "$MNT"; die "cannot replace grub.cfg"; }

grep -q "$TARGET_ESP_PARTUUID" "$MNT/grub.cfg" \
    || { umount "$MNT"; die "grub.cfg still points at the source disk"; }

sync
umount "$MNT"

# --------------------------------------------------------------- finish ----
sync
sgdisk -e "$TGT_DISK" >/dev/null 2>&1 || true

echo
echo "==============================================================="
echo "  Installed to $TGT_NAME."
echo
echo "  userdata is ${DATA_MB} MiB -- the rest of the disk."
echo
echo "  Remove the USB device, then reboot. If the machine still boots"
echo "  from USB, change the boot order in firmware."
echo "==============================================================="
echo
say "install complete: $TGT_NAME, userdata ${DATA_MB} MiB"

printf "  Press enter to reboot: "
read _
reboot
