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
#     sudo mount -o ro /dev/sdX5 /mnt && less /mnt/bootlog.txt
#
# Started from a trigger that fires after /data is mounted -- starting earlier
# would land the file on the read-only ramdisk.
#
# Keeps the previous boot's log as bootlog.prev.txt so a failed boot is not
# overwritten by the retry that follows it.

OUT=/data/bootlog.txt
PREV=/data/bootlog.prev.txt

[ -f "$OUT" ] && mv -f "$OUT" "$PREV"

# -b all covers main, system, crash, events and kernel.
exec /system/bin/logcat -b all -v threadtime > "$OUT"
