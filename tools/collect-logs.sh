#!/usr/bin/env bash
#
# Pull the kernel log and logcat off a device that was booted on real hardware,
# and summarise why the display did or did not come up.
#
#   ./build.sh logs                 auto-detect the USB disk
#   ./build.sh logs /dev/sdX        name it explicitly
#
# The guest writes /data/kmsg.txt and /data/bootlog.txt (see
# pc_kmsg_file.sh / pc_logcat_file.sh). userdata is plain ext4, so this just
# mounts it read-only and copies them out. Nothing is written to the device.
#
set -uo pipefail

X86_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$X86_ROOT/out/hw-logs/$(date +%Y%m%d-%H%M%S)"

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else R=''; G=''; Y=''; B=''; N=''; fi
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

TARGET="${1:-}"

# Find the disk carrying a partition labelled 'userdata' on a USB transport.
if [[ -z "$TARGET" ]]; then
    info "looking for the Android disk"
    while read -r name tran; do
        [[ "$tran" == "usb" ]] || continue
        if lsblk -no PARTLABEL "/dev/$name" 2>/dev/null | grep -qx userdata; then
            TARGET="/dev/$name"; break
        fi
    done < <(lsblk -dno NAME,TRAN 2>/dev/null)
    [[ -n "$TARGET" ]] || die "no USB disk with a 'userdata' partition found; pass it explicitly"
    ok "found $TARGET"
fi

[[ -b "$TARGET" ]] || die "not a block device: $TARGET"

# userdata is the partition labelled as such, not a fixed index.
PART=""
for p in "$TARGET"*; do
    [[ "$p" == "$TARGET" ]] && continue
    [[ "$(lsblk -no PARTLABEL "$p" 2>/dev/null)" == "userdata" ]] && { PART="$p"; break; }
done
[[ -n "$PART" ]] || die "no partition labelled 'userdata' on $TARGET"
ok "userdata: $PART"

mkdir -p "$OUT"
MNT=$(mktemp -d)
cleanup() { sudo umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null; }
trap cleanup EXIT

# Read-only: a half-written ext4 from a hard power-off should not be modified.
info "mounting read-only"
sudo mount -o ro "$PART" "$MNT" 2>/dev/null \
    || die "mount failed. If the device was powered off abruptly the journal may
     need replaying:  sudo e2fsck -fy $PART   (this MODIFIES the filesystem)"

# Where to look, in order of preference. pc_kmsg_file.sh and pc_logcat_file.sh
# write under /data/local/tmp, which is "local/tmp" once userdata is mounted
# here -- not the root of the partition. Looking only at the root is why this
# reported "no logs found" on a disk that had four of them, so the root stays in
# the list as a fallback rather than being swapped out for the right path.
SUBDIRS=(local/tmp vendor/pc .)

copied=0
for f in kmsg.txt kmsg.prev.txt bootlog.txt bootlog.prev.txt pc_install.log; do
    for d in "${SUBDIRS[@]}"; do
        src="$MNT/$d/$f"
        [[ -f "$src" ]] || continue
        sudo cp "$src" "$OUT/$f" 2>/dev/null && copied=1
        # SUDO_USER, not USER: this script is normally run as `sudo collect-logs`,
        # where $USER is root, so chowning to it leaves the caller unable to read
        # the logs they just asked for without sudo.
        sudo chown "${SUDO_USER:-$USER}" "$OUT/$f" 2>/dev/null
        printf '  %-20s %-10s %s\n' "$f" "$(du -h "$OUT/$f" | cut -f1)" "${d#.}"
        break
    done
done
(( copied )) || die "no logs found on $PART (looked in ${SUBDIRS[*]}) -- did the boot get far enough to mount /data?"

# ------------------------------------------------------------- summary ----
K="$OUT/kmsg.txt"; L="$OUT/bootlog.txt"

echo; info "graphics hardware"
if [[ -f "$K" ]]; then
    grep -aiE 'drm|i915|amdgpu|nouveau|radeon|xe ' "$K" 2>/dev/null \
        | grep -aiE 'initialized|bound|failed|error|firmware|no connectors|disabling' \
        | head -12 | sed 's/^/  /' | cut -c1-160
    echo
    printf '  %-28s %s\n' "DRM driver bound:" \
        "$(grep -aoE '\[drm\] Initialized [a-z_]+' "$K" 2>/dev/null | head -1 | sed 's/.*Initialized //' || echo 'NONE FOUND')"
    printf '  %-28s %s\n' "firmware errors:" "$(grep -acE 'firmware.*fail|Direct firmware load.*failed' "$K" 2>/dev/null)"
    printf '  %-28s %s\n' "/dev/dri nodes:" "$(grep -aA6 'graphics ===' "$K" 2>/dev/null | grep -c 'card\|render')"
fi

echo; info "network (for adb)"
[[ -f "$K" ]] && grep -aE 'inet ' "$K" 2>/dev/null | head -4 | sed 's/^/  /'

if [[ -f "$L" ]]; then
    echo; info "userspace"
    printf '  %-28s %s\n' "native crashes:"  "$(grep -ac 'Fatal signal' "$L" 2>/dev/null)"
    printf '  %-28s %s\n' "java fatals:"     "$(grep -ac 'FATAL EXCEPTION' "$L" 2>/dev/null)"
    printf '  %-28s %s\n' "watchdog kills:"  "$(grep -ac 'WATCHDOG KILLING' "$L" 2>/dev/null)"
    printf '  %-28s %s\n' "boot finished:"   "$(grep -aoE 'Boot is finished \([0-9]+ ms\)' "$L" 2>/dev/null | head -1 || echo NO)"
    printf '  %-28s %s\n' "drm fb failures:" "$(grep -ac 'could not create drm fb' "$L" 2>/dev/null)"
    printf '  %-28s %s\n' "BAD_DISPLAY:"     "$(grep -ac 'BAD_DISPLAY' "$L" 2>/dev/null)"
    echo
    info "surfaceflinger / composer errors"
    grep -aE 'E SurfaceFlinger|E drmhwc|F SurfaceFlinger' "$L" 2>/dev/null \
        | sed 's/.*: //' | sort | uniq -c | sort -rn | head -6 | sed 's/^/  /' | cut -c1-150
fi

echo; ok "logs in $OUT"
