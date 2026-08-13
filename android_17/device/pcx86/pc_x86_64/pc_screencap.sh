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
# Instead: start early, retry, and stop as soon as the capture looks like a
# real frame. A blank screen compresses to a few KB as PNG, a drawn UI does
# not, so size is a good enough test for "something is on screen".
DELAY=${1:-15}
TRIES=${2:-12}
INTERVAL=${3:-5}
MIN_BYTES=${MIN_BYTES:-20000}

# Send the PNG base64-encoded between markers, not raw.
#
# $OUT is a tty, so the line discipline rewrites every \n as \r\n on the way
# out. That silently corrupts binary: a 727916-byte PNG arrived on the host as
# 730412 bytes -- 2496 newlines expanded -- and even its magic bytes were split
# (\x89PNG\r\n... became \x89PNG\r\r\n...), so the file was unreadable and did
# not look like a PNG at all.
#
# base64 is immune to that, and the markers let the host find the payload
# amongst the OVMF escape sequences that firmware writes to the same port
# before Android boots.
emit() {
    {
        echo "---PC-SCREENCAP-BEGIN---"
        base64 "$TMP"
        echo "---PC-SCREENCAP-END---"
    } > "$OUT"
    log -t pc-screencap "wrote $1 bytes (base64) to $OUT"
}

log -t pc-screencap "started, delay=${DELAY}s tries=$TRIES"
sleep "$DELAY"

i=0
last=0
while [ "$i" -lt "$TRIES" ]; do
    # Log before the capture, not only after, and bound it with timeout.
    # screencap talks to SurfaceFlinger, and when the display is wedged that
    # call can block forever -- which is indistinguishable, from the outside,
    # from the service never having started at all. An earlier revision logged
    # only after the capture returned and so reported nothing whatsoever.
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
