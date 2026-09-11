#!/system/bin/sh
#
# Persist logcat to /data so a boot can be diagnosed on real hardware.
#
# The other logcat service writes to /dev/hvc1, a virtio-console port that only
# exists under QEMU. On a physical machine that device is absent, so the boot
# produces no readable log at all -- which is exactly when one is needed most.
#
# This writes to /data instead. After a boot, plug the disk into a workstation
# and read it directly; userdata is plain ext4:
#
#     sudo mount -o ro /dev/sdX5 /mnt && less /mnt/local/tmp/bootlog.txt
#
# Started from a trigger that fires after /data is mounted -- starting earlier
# would land the file on the read-only ramdisk.
#
# Keeps the previous boot's log as bootlog.prev.txt so a failed boot is not
# overwritten by the retry that follows it.

OUT=/data/local/tmp/bootlog.txt
PREV=/data/local/tmp/bootlog.prev.txt

[ -f "$OUT" ] && mv -f "$OUT" "$PREV"

# -b all covers main, system, crash, events and kernel.
# Continuous streaming is OFF unless androidboot.pc_logs=1 is on the kernel
# command line. It is not free, and on this port it was the single largest
# source of jank.
#
# Measured on the HP laptop booted from the T7, so /data lives on USB: this
# service writes roughly 109 lines per SECOND to that external SSD. Same
# scrolling-UI benchmark, with and without it:
#
#     capture running   213 frames, 145 MISSED, 26.9 ms/frame
#     capture stopped   275 frames,   3 missed, 19.3 ms/frame
#
# A 98% drop in missed frames. The jank was the logging, not the GPU.
#
# pc-kmsg-file still runs unconditionally: it is oneshot, dumps the kernel ring
# buffer once, and costs nothing, so a boot that never lights up the screen can
# still be explained without setting any flag.
[ "$(getprop ro.boot.pc_logs)" = "1" ] || exit 0

exec /system/bin/logcat -b all -v threadtime > "$OUT"
