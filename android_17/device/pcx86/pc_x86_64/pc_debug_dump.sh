#!/system/bin/sh
#
# Bring-up diagnostics, written to the virtio-console port the QEMU harness
# captures (tools/run-qemu.sh). Started from init.pc_x86_64.rc.
#
# Exists because init's own messages are split across two streams -- kmsg
# early, logd once it is up -- which makes "did init ever try to start this
# service?" surprisingly hard to answer. init.svc.<name> is unambiguous:
# empty means init does not know the service at all, otherwise it is
# running/stopped/restarting.
#
# This is a debugging aid, not part of the product. Remove once boot is clean.

OUT=/dev/hvc1

{
    echo "=== PC DEBUG DUMP ==="

    echo "--- init service states ---"
    for svc in \
        vendor.audio-hal-aidl \
        vendor.audio-effect-hal-aidl \
        audioserver \
        vendor.hwcomposer-3 \
        vendor.graphics.allocator \
        vendor.keymint-default \
        vendor.power-default
    do
        echo "init.svc.$svc = [$(getprop init.svc.$svc)]"
    done

    echo "--- apex activation ---"
    echo "apexd.status = [$(getprop apexd.status)]"
    ls /apex/ 2>&1 | grep -i audio

    echo "--- audio apex payload ---"
    ls -lZ /apex/com.android.hardware.audio/bin/hw/ 2>&1

    echo "--- audio HAL declared in vintf? ---"
    cat /apex/com.android.hardware.audio/etc/vintf/*.xml 2>&1 | head -20

    echo "--- screencap plumbing ---"
    echo "init.svc.pc-screencap = [$(getprop init.svc.pc-screencap)]"
    ls -l /dev/hvc* 2>&1
    ls -l /vendor/bin/pc_screencap.sh 2>&1
    echo "screencap binary: $(ls -l /system/bin/screencap 2>&1)"

    echo "--- bpffs labels ---"
    ls -ldZ /sys/fs/bpf /sys/fs/bpf/net_shared /sys/fs/bpf/netd_shared 2>&1

    echo "=== END PC DEBUG DUMP ==="
} > "$OUT" 2>&1
