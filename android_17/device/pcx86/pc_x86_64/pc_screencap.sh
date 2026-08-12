#!/system/bin/sh
#
# Write what SurfaceFlinger actually composited to the virtio-console port the
# QEMU harness captures (tools/run-qemu.sh -> out/disk/screencap.png).
#
# This is the only way to see the UI in the VM: the virtio-gpu KMS primary
# plane only accepts XRGB8888, so Android's composed buffers can never be
# scanned out and the host framebuffer stays blank, and adb over TCP is
# refused. screencap reads SurfaceFlinger's output directly, before any of
# that, so what lands here is the real UI.
#
# A script rather than an inline `sh -c` in init.pc_x86_64.rc: init's rc
# parser does not handle a ';' inside the quoted argument, so the inline form
# silently never started (it appeared in neither logcat nor the init log,
# while pc_debug_dump.sh fired from the same trigger).
#
# Debugging aid; remove once the display works.

OUT=/dev/hvc2
TMP=/data/local/tmp/screencap.png

# The trigger fires early, so wait for the UI to actually draw something.
sleep "${1:-60}"

# Capture to a file first so the exit status and size are observable; a bare
# redirect into the character device hides both.
/system/bin/screencap -p "$TMP"
rc=$?
sz=$(stat -c%s "$TMP" 2>/dev/null || echo 0)
log -t pc-screencap "screencap rc=$rc size=$sz"

if [ "$rc" -eq 0 ] && [ "$sz" -gt 0 ]; then
    cat "$TMP" > "$OUT"
    log -t pc-screencap "wrote $sz bytes to $OUT"
else
    log -t pc-screencap "capture failed, nothing written"
fi
