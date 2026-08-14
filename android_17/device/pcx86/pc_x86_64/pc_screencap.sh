#!/system/bin/sh
#
# Write what SurfaceFlinger actually composited to the virtio-console port the
# QEMU harness captures (tools/run-qemu.sh -> out/disk/screencap.png).
#
# This is the only way to see the UI in the VM. virtio-gpu's KMS accepts only
# ARGB8888/XRGB8888 framebuffers while the software renderer produces
# ABGR8888, so Android's composed buffers can never be scanned out and the
# host framebuffer stays blank (doc/05-graphics.md 5.1); adb over TCP is
# refused as well. screencap reads SurfaceFlinger's output directly, before
# either of those, so what lands here is the real UI.
#
# A script rather than an inline `sh -c` in init.pc_x86_64.rc: init's rc
# parser does not handle a ';' inside the quoted argument, so the inline form
# silently never started (it appeared in neither logcat nor the init log,
# while pc_debug_dump.sh fired from the same trigger).
#
# Debugging aid; remove once the display works.

OUT=/dev/hvc2
TMP=/data/local/tmp/screencap.png

# Poll rather than sleeping once and hoping.
#
# The trigger is init.svc.audioserver=running, which fires early -- long before
# anything is drawn -- so the capture has to be delayed. A single fixed sleep
# was the previous approach and it lost the race: 60s landed at roughly 80s
# into the boot, while the test harness collects and powers off at about 85s,
# so the write to $OUT never completed and the file held nothing but the OVMF
# escape sequences that firmware had already sent to the same port.
#
# Wait for the launcher, do not guess from the file size.
#
# An earlier version slept, captured, and accepted the first frame over 20 KB
# on the theory that a blank screen compresses small and a drawn UI does not.
# That is true but insufficient: the *boot animation* is also a drawn UI, and
# at 2560x1600 its frame is 52 KB, so the check passed and the capture stopped
# on the Android logo -- the very screen nobody wants a picture of. Resolution
# made it worse only by slowing SwiftShader down; the flaw was always there.
#
# Use the same definition of "booted" the host harness uses: launcher3 gaining
# top-resumed. Reading our own logcat for it costs nothing and cannot be fooled
# by an intermediate screen.
LAUNCHER_PAT=${LAUNCHER_PAT:-wm_on_top_resumed_gained_called.*[Ll]auncher}
WAIT=${WAIT:-240}
SETTLE=${SETTLE:-8}
TRIES=${TRIES:-6}
INTERVAL=${INTERVAL:-5}
MIN_BYTES=${MIN_BYTES:-20000}

emit() {
    {
        echo "---PC-SCREENCAP-BEGIN---"
        base64 "$TMP"
        echo "---PC-SCREENCAP-END---"
    } > "$OUT"
    log -t pc-screencap "wrote $1 bytes (base64) to $OUT"
}

log -t pc-screencap "started, waiting up to ${WAIT}s for the launcher"

waited=0
while [ "$waited" -lt "$WAIT" ]; do
    if logcat -d -b all 2>/dev/null | grep -qE "$LAUNCHER_PAT"; then
        log -t pc-screencap "launcher up after ${waited}s"
        break
    fi
    waited=$((waited + 2))
    sleep 2
done
[ "$waited" -ge "$WAIT" ] && log -t pc-screencap "launcher never seen; capturing anyway"

# Let the first frame settle -- top-resumed fires before the window is drawn.
sleep "$SETTLE"

i=0
last=0
while [ "$i" -lt "$TRIES" ]; do
    log -t pc-screencap "try=$i capturing"
    timeout 20 /system/bin/screencap -p "$TMP"
    rc=$?
    sz=$(stat -c%s "$TMP" 2>/dev/null || echo 0)
    log -t pc-screencap "try=$i rc=$rc size=$sz"

    if [ "$rc" -eq 0 ] && [ "$sz" -gt "$MIN_BYTES" ]; then
        emit "$sz"
        exit 0
    fi

    [ "$sz" -gt 0 ] && last="$sz"
    i=$((i + 1))
    sleep "$INTERVAL"
done

# Nothing crossed the threshold. Ship the last capture regardless -- a blank
# frame that proves screencap works is more useful than no file at all.
if [ "$last" -gt 0 ]; then
    emit "$last"
    log -t pc-screencap "that capture was under $MIN_BYTES; screen may be blank"
else
    log -t pc-screencap "capture failed after $TRIES tries, nothing written"
fi
