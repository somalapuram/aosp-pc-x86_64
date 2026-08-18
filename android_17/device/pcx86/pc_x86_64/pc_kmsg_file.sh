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

OUT=/data/local/tmp/kmsg.txt
PREV=/data/local/tmp/kmsg.prev.txt

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

# Follow the kernel log if we are allowed to, and do not spin if we are not.
#
# Neither route works from the shell domain on a stock kernel. `dmesg -w` reads
# the ring buffer via syslog(2), which wants CAP_SYS_ADMIN/CAP_SYSLOG; reading
# /dev/kmsg directly wants CAP_SYSLOG too, because kernel.dmesg_restrict gates
# it regardless of the node being root:log and shell being in that group. And
# shell is an appdomain, which app_neverallows.te forbids any capability at all.
#
# Running as root instead is not a way out: root in the shell domain needs
# CAP_DAC_OVERRIDE for its usual bypass, which is refused the same way.
#
# So take it if it is there, and otherwise exit cleanly. Exiting non-zero made
# init restart the service forever -- 33 times in one boot -- which is noise
# that buries the real log. The header above is the useful part on a device
# with no serial console anyway; the kernel log itself is on ttyS0 and hvc0.
if cat /dev/kmsg >> "$OUT" 2>/dev/null; then
    :
else
    echo "=== /dev/kmsg unreadable (dmesg_restrict, needs CAP_SYSLOG) ===" >> "$OUT"
    echo "=== see ttyS0 or hvc0 for the kernel log ===" >> "$OUT"
fi
exit 0
