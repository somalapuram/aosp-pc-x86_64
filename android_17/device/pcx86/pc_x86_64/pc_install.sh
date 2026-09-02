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

# "<3>" is KERN_ERR, and it is the difference between a log line and no log line.
# A bare write to /dev/kmsg is recorded at the default level of 4, and the
# install entry boots with loglevel=4, which prints only levels BELOW 4. So
# every say() went into the ring buffer and none of it reached the console --
# during a bring-up run that showed up as an installer with no output at all,
# indistinguishable from one that never started. Levels 0-3 print at any
# loglevel this image uses, so the installer is audible wherever it runs.
# Every line goes three places, and the third is the one that matters after the
# fact. kmsg is for the running console; stdout is for the person watching; and
# TRANSCRIPT is a plain file on the source stick, appended a line at a time.
#
# The transcript exists because the other two do not survive. pc_logcat_file.sh
# is a `logcat > file` redirect with no periodic flush, so it is block-buffered,
# and this script reboots the moment the user presses enter -- which discards
# whatever is still in that buffer. A completed install therefore left a log
# that stopped at the confirmation prompt, indistinguishable from one that was
# never answered. Appending with >> reopens and closes per line, so each line is
# on disk before the next runs, and the record survives the reboot.
TRANSCRIPT=/data/local/tmp/pc_install.log
say() {
    echo "<3>pc_install: $*" > "$LOG"
    echo "pc_install: $*"
    echo "$(date '+%H:%M:%S' 2>/dev/null) $*" >> "$TRANSCRIPT" 2>/dev/null || true
}
die() {
    echo "<3>pc_install: FAILED: $*" > "$LOG"
    echo "$(date '+%H:%M:%S' 2>/dev/null) FAILED: $*" >> "$TRANSCRIPT" 2>/dev/null || true
    sync 2>/dev/null || true
    echo; echo "  FAILED: $*"; echo
    exit 1
}

# Sizes come from sysfs, not blockdev.
#
# /sys/class/block/<dev>/size is the kernel's own view, in 512-byte sectors, and
# it needs no helper binary. The previous blockdev call failed here and the
# helper made that failure unreadable: on error it echoed "0" AND then echoed an
# arithmetic expansion of an empty variable, so the caller captured two lines and
# every size comparison downstream was against garbage.
# Sizes are computed in MEBIBYTES, never in bytes, and that is not a style
# choice. /system/bin/sh is mksh and its arithmetic is 32-bit, so a byte count
# for any modern disk overflows silently and the result is not merely wrong, it
# is plausible: a 20 GiB target is 41943040 sectors, times 512 is 21474836480,
# which is exactly 5*2^32 and therefore wraps to 0 -- so "cannot size" fired on
# a disk whose size had been read correctly a microsecond earlier. A 6 GiB
# system partition wraps to 2147483648, which is negative as a signed 32-bit
# int, so its "> 0" check failed the same way for the opposite reason.
#
# Sectors are 512 bytes, so MiB is sectors/2048, and every value stays small.
#
# Three path spellings, because one does not cover both cases: a whole disk is
# /sys/block/<disk>, while a partition lives under its parent as
# /sys/block/<disk>/<part>. /sys/class/block/<any> should cover both and is
# kept last as a fallback.
dev_mb() {
    n=${1##*/}
    for f in "/sys/block/$n/size" /sys/block/*/"$n"/size "/sys/class/block/$n/size"; do
        [ -r "$f" ] || continue
        sec=$(cat "$f" 2>/dev/null)
        case "$sec" in ''|*[!0-9]*) continue ;; esac
        echo $(( sec / 2048 ))
        return 0
    done
    # blockdev reports bytes; --getsz reports 512-byte sectors, which is what we
    # want for the same overflow reason.
    sec=$(blockdev --getsz "$1" 2>/dev/null)
    case "$sec" in ''|*[!0-9]*) sec=0 ;; esac
    echo $(( sec / 2048 ))
}

src_part_mb() { dev_mb "$1"; }

# The layout mirrors tools/mkdisk.sh exactly. If that file changes, this must
# change with it -- the installed system is meant to be indistinguishable from
# a freshly written stick apart from userdata's size.
ESP_MB=512
METADATA_MB=64
TARGET_ESP_PARTUUID=9d4ae3f2-1e6b-4a58-8b3c-000000000002

# ---------------------------------------------------------------- gate ----
# Announce the start on kmsg before anything else. Everything below this talks
# to stdout, which is /dev/console, and if that console is not the one the user
# is looking at then the installer is invisible and indistinguishable from one
# that never ran -- which is exactly how an earlier boot presented, with the
# script blocked on its confirmation prompt over a serial port and not one line
# of evidence in any log. kmsg reaches the collected logs either way, so a later
# "did it even start?" is answerable.
say "starting (pc_install=$(getprop ro.boot.pc_install), console=$(tty 2>/dev/null || echo unknown))"

[ "$(getprop ro.boot.pc_install)" = "1" ] || {
    say "not install mode, doing nothing"
    exit 0
}

# Take the console for ourselves.
#
# This screen is about to ask a question that erases a disk, and it has to be
# readable while it does. With surfaceflinger and zygote stopped, servicemanager
# retries 'activity' and SurfaceFlingerAIDL as lazy services once a second and
# init logs each failure through printk, which lands on tty0 and scrolls the
# prompt away. The GRUB entry already passes loglevel=1; this sets it again from
# here so the installer does not depend on the command line being right, and so
# it still holds if anything raised the level during boot.
#
# Only printk is affected. Everything this script echoes goes to stdout on
# /dev/console, which the console loglevel does not filter, so the banner, the
# plan and the prompt are all unaffected.
echo 1 > /proc/sys/kernel/printk 2>/dev/null || true

# Take sole ownership of the console, from here rather than from an rc file.
#
# AOSP runs `service console /system/bin/sh` with the `console` option whenever
# ro.debuggable=1, and this device's own rc starts it a second time. That shell
# holds the SAME /dev/console this script prompts on, and both read it, so the
# user's typing is split between two readers a byte at a time: a typed ERASE
# reached this script as RASE, every attempt, three attempts running.
#
# Stopping it from init.pc_x86_64.rc was tried at post-fs-data and again at
# boot, and neither stuck, because `on property:ro.debuggable=1` re-starts it
# from queue_property_triggers in between. Doing it here settles the ordering
# question entirely: this line runs when the installer runs, which is after
# every trigger init has to offer. ctl.stop is the documented way to ask init
# to stop a service from outside init.
setprop ctl.stop console 2>/dev/null || true

# Give init a moment to reap it before we start reading the terminal it held.
sleep 1

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

# Three ways to resolve it, because the obvious one does not work here.
#
# blkid was the original method and it silently finds nothing: this image ships
# AOSP's minimal blkid, which identifies filesystems by reading superblocks and
# never looks at the GPT, so "-s PARTUUID" returns empty for every partition and
# the loop falls through to a failure that reads as if the disk were missing.
#
# by-name is tried first because init has already done this work. It resolves
# androidboot.boot_part_uuid to the boot device and creates /dev/block/by-name/*
# for that device's partitions only, so by-name/esp IS the ESP we booted from,
# by construction, with no scanning and no ambiguity when two disks carry the
# same layout -- which is exactly the situation during an install.
#
# sgdisk is the fallback and reads the GPT itself, which is the authority for a
# partition GUID. Slower (one exec per partition) but it cannot be fooled.
find_src_by_name() {
    [ -L /dev/block/by-name/esp ] || return 1
    readlink -f /dev/block/by-name/esp 2>/dev/null
}

find_src_by_sgdisk() {
    for sysdisk in /sys/block/*; do
        n=$(basename "$sysdisk")
        case "$n" in loop*|ram*|zram*|dm-*|sr*|md*) continue ;; esac
        [ -b "/dev/block/$n" ] || continue
        for i in 1 2 3 4 5 6 7 8; do
            g=$(sgdisk --info="$i" "/dev/block/$n" 2>/dev/null \
                | sed -n 's/^Partition unique GUID: *//p' \
                | tr 'A-Z' 'a-z')
            [ -n "$g" ] || continue
            if [ "$g" = "$(echo "$SRC_UUID" | tr 'A-Z' 'a-z')" ]; then
                case "$n" in
                    nvme*|mmcblk*) echo "/dev/block/${n}p${i}" ;;
                    *)             echo "/dev/block/${n}${i}" ;;
                esac
                return 0
            fi
        done
    done
    return 1
}

SRC_PART=$(find_src_by_name) && [ -n "$SRC_PART" ] \
    && say "source found via by-name: $SRC_PART" \
    || {
        SRC_PART=$(find_src_by_sgdisk) && [ -n "$SRC_PART" ] \
            && say "source found via sgdisk GPT scan: $SRC_PART"
    }

[ -n "$SRC_PART" ] || die "cannot find the partition we booted from ($SRC_UUID).
         by-name/esp: $([ -L /dev/block/by-name/esp ] && readlink -f /dev/block/by-name/esp || echo absent)
         block devices: $(ls /dev/block/ 2>/dev/null | tr '\n' ' ')"

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

TGT_MB=$(dev_mb "$TGT_DISK")
[ "$TGT_MB" -gt 0 ] || die "cannot size $TGT_DISK
         /sys/block/$TGT_NAME/size: $(cat "/sys/block/$TGT_NAME/size" 2>/dev/null || echo unreadable)"
say "target $TGT_NAME is ${TGT_MB} MiB"

# ----------------------------------------------------------- size check ----
# Name the source partitions once. nvme and mmc insert a 'p' before the number,
# sd does not; deciding that per use produced two spellings of the same path.
case "$SRC_NAME" in
    nvme*|mmcblk*) SRC_P="${SRC_DISK}p" ;;
    *)             SRC_P="${SRC_DISK}"  ;;
esac

SYSTEM_MB=$(src_part_mb "${SRC_P}2")
VENDOR_MB=$(src_part_mb "${SRC_P}3")
say "source sizes: system=${SYSTEM_MB}MiB vendor=${VENDOR_MB}MiB"
[ "$SYSTEM_MB" -gt 0 ] || die "cannot read the source system partition (${SRC_P}2)"
[ "$VENDOR_MB" -gt 0 ] || die "cannot read the source vendor partition (${SRC_P}3)"

FIXED_MB=$(( ESP_MB + SYSTEM_MB + VENDOR_MB + METADATA_MB + 16 ))
DATA_MB=$(( TGT_MB - FIXED_MB ))
[ "$DATA_MB" -ge 2048 ] || die "$TGT_NAME is ${TGT_MB} MiB; needs at least $(( FIXED_MB + 2048 ))"

# -------------------------------------------------------------- confirm ----
echo "  Source (this USB device)   $SRC_NAME"
echo "  Target (will be ERASED)    $TGT_NAME   ${TGT_MB} MiB"
echo
echo "  Current contents of $TGT_NAME:"
sgdisk --print "$TGT_DISK" 2>/dev/null | sed -n '/Number/,$p' | sed 's/^/    /' || echo "    (no partition table)"
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
# Ask up to three times rather than aborting on the first mismatch.
#
# The gate is unchanged -- nothing proceeds without the exact word ERASE -- but
# a single wrong keystroke used to end the attempt and cost a full reboot to try
# again. That is a bad trade for a confirmation prompt: the user who typed the
# word meant it, and the user who fumbled it did not mean "cancel". Observed
# concretely on the QEMU harness, where the console reliably swallows the first
# byte after the prompt and a typed ERASE arrives as RASE.
# Confirmation may already have been given at the boot menu.
#
# The typed prompt below needs the kernel's VT layer to deliver keystrokes to
# /dev/console, and on this hardware it does not -- the prompt draws, the
# keyboard does nothing, and the install cannot proceed no matter how long the
# user waits. GRUB's input works (its menu is how this entry got selected), so
# the "NO PROMPT" entry answers the question there and passes the answer here.
#
# The value must be exactly ERASE, the same word the prompt demands, so there is
# one answer and one spelling of it wherever it is given.
BOOT_CONFIRM=$(getprop ro.boot.pc_install_confirm)
if [ "$BOOT_CONFIRM" = "ERASE" ]; then
    ANSWER=ERASE
    attempt=0
    say "confirmed at the boot menu (androidboot.pc_install_confirm=ERASE)"
    echo
    echo "  Confirmed by the boot menu entry. Installing without a prompt."
    echo
else

say "waiting for confirmation on the console"
ANSWER=""
attempt=0
while [ "$attempt" -lt 3 ]; do
    attempt=$(( attempt + 1 ))
    printf "  Type ERASE to continue, anything else to abort: "
    read ANSWER
    ANSWER=$(echo "$ANSWER" | tr -d ' \t\r\n')
    [ "$ANSWER" = "ERASE" ] && break
    say "attempt $attempt: answer was [$ANSWER], not ERASE"
    [ "$attempt" -lt 3 ] && echo "  Not recognised. Type exactly ERASE, or press enter twice to abort."
    [ "$attempt" -ge 3 ] && {
        echo
        echo "  If the keyboard does nothing here, this machine does not deliver"
        echo "  console keystrokes. Reboot and choose the last GRUB entry,"
        echo "  \"Install ... NO PROMPT\", which confirms at the menu instead."
        echo
    }
done
fi

# Log the answer, and log the abort. Declining used to exit 0 in silence, which
# is indistinguishable in a log from the installer never having run -- the same
# ambiguity that hid every earlier failure in this script.
say "confirmation read: [$ANSWER]"
[ "$ANSWER" = "ERASE" ] || {
    say "aborted after $attempt attempts. Nothing was written."
    echo; echo "  Aborted. Nothing was written."; echo
    exit 0
}
echo

# ------------------------------------------------------------ partition ----
# LONG OPTIONS ONLY. The sgdisk on this device is external/gptfdisk built
# against android_popt.cc, a stand-in for popt that calls getopt_long with an
# EMPTY short-option string -- so every short flag is rejected outright:
#     sgdisk: invalid option -- n
#     Problem opening 1:1MiB:+512MiB for reading! Error is 2.
# The second line is the giveaway: with -n unrecognised, its argument was left
# on the command line and taken as the device to open. Upstream sgdisk accepts
# both forms, so this reads as valid everywhere except where it runs.
say "partitioning $TGT_NAME"
sgdisk --zap-all "$TGT_DISK" >/dev/null 2>&1 || true
SG_ERR=$(sgdisk \
    --new=1:2048:+${ESP_MB}M      --typecode=1:ef00 --change-name=1:esp \
    --new=2:0:+${SYSTEM_MB}M      --typecode=2:8300 --change-name=2:system \
    --new=3:0:+${VENDOR_MB}M      --typecode=3:8300 --change-name=3:vendor \
    --new=4:0:+${METADATA_MB}M    --typecode=4:8300 --change-name=4:metadata \
    --new=5:0:0                   --typecode=5:8300 --change-name=5:userdata \
    --partition-guid=1:"$TARGET_ESP_PARTUUID" \
    "$TGT_DISK" 2>&1) || die "sgdisk failed on $TGT_DISK
         $SG_ERR"
blockdev --rereadpt "$TGT_DISK" 2>/dev/null || true
sleep 2

# nvme and mmc insert a 'p' before the partition number; sd does not.
case "$TGT_NAME" in nvme*|mmcblk*) P="p" ;; *) P="" ;; esac
tp() { echo "${TGT_DISK}${P}$1"; }
sp() { echo "${SRC_P}$1"; }

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
sgdisk --move-second-header "$TGT_DISK" >/dev/null 2>&1 || true

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

# Flush before handing control away. sync is not enough on its own for the
# logcat file (its buffer is in userspace), but it is what makes this script's
# own transcript durable, and the transcript is the record that matters.
say "rebooting"
sync 2>/dev/null || true

printf "  Press enter to reboot: "
read _
sync 2>/dev/null || true
reboot
