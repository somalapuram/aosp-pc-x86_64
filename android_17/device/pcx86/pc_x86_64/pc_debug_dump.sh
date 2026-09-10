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

# /dev/hvc1 is a virtio-console: it exists under QEMU and nowhere else, so on
# real hardware this dump went to a device that was not there and the whole
# thing was invisible. Write a second copy where tools/collect-logs.sh can find
# it -- it already scans /data/local/tmp for kmsg.txt and bootlog.txt.
#
# Worth having on its own: whether a GL client got the GPU-selection property is
# a one-line question, and answering it from logcat alone took a boot cycle.
FILE=/data/local/tmp/props.txt

gpu_state() {
    echo "=== GPU SELECTION ==="
    for p in drm.gpu.vendor_name vendor.pc.gpu ro.hardware.egl ro.hardware.gralloc \
             ro.hardware.vulkan vendor.hwc.drm.device; do
        echo "$p = [$(getprop $p)]"
    done
    echo "--- cards, connectors and who drives what ---"
    for c in /sys/class/drm/card[0-9]; do
        [ -e "$c" ] || continue
        echo "$(basename "$c"): driver=$(basename "$(readlink -f "$c/device/driver" 2>/dev/null)" 2>/dev/null) boot_vga=$(cat "$c/device/boot_vga" 2>/dev/null)"
        for conn in "$c"-*; do
            [ -e "$conn/status" ] || continue
            echo "    $(basename "$conn") = $(cat "$conn/status" 2>/dev/null)"
        done
    done
    echo "--- dri nodes ---"
    ls -lZ /dev/dri/ 2>&1
    echo "=== END GPU SELECTION ==="
}

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

    gpu_state
    echo "=== END PC DEBUG DUMP ==="
# If /dev/hvc1 is absent -- i.e. anywhere that is not QEMU -- redirecting to it
# fails and takes the whole pipeline with it, losing the /data copy too. Fall
# back to /dev/null so the file is written regardless.
[ -w "$OUT" ] || OUT=/dev/null
} 2>&1 | tee "$FILE" > "$OUT"
