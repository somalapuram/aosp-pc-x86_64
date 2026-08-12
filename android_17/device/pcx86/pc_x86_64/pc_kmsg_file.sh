#!/system/bin/sh
#
# Persist the kernel log to /data so a boot on real hardware can be diagnosed.
#
# On a physical machine there is no virtio-console and usually no serial port
# to hand, so the kernel ring buffer is lost on power-off. That buffer is
# where the answers live for a display that never lights up: which DRM driver
# bound (i915 / xe / amdgpu / nouveau / none), whether its firmware loaded,
# which connectors were found and what modes they advertise.
#
# `dmesg -w` follows the buffer, so messages that arrive after this starts are
# captured too -- a snapshot would miss anything that goes wrong later.
# Everything already in the ring buffer at start is included as well, so no
# early boot output is lost by starting late.
#
# Read it afterwards on a workstation; userdata is plain ext4:
#     sudo mount -o ro /dev/sdX5 /mnt && less /mnt/kmsg.txt
# or use tools/collect-logs.sh, which does that and summarises the result.

OUT=/data/kmsg.txt
PREV=/data/kmsg.prev.txt

[ -f "$OUT" ] && mv -f "$OUT" "$PREV"

# Record the network address too. If the machine has a working NIC this is how
# to reach it with `adb connect <ip>:5555` instead of moving the disk around.
{
    echo "=== interfaces at $(date) ==="
    ip addr show 2>/dev/null | grep -E '^[0-9]+:|inet '
    echo "=== adb ==="
    echo "service.adb.tcp.port = $(getprop service.adb.tcp.port)"
    echo "init.svc.adbd        = $(getprop init.svc.adbd)"
    echo "=== graphics ==="
    echo "ro.hardware.egl      = $(getprop ro.hardware.egl)"
    echo "ro.hardware.vulkan   = $(getprop ro.hardware.vulkan)"
    ls -l /dev/dri/ 2>&1
    echo "=== kernel log follows ==="
} > "$OUT"

exec /system/bin/dmesg -w >> "$OUT"
