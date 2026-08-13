#!/usr/bin/env bash
#
# Boot the pc_x86_64 image in QEMU/KVM and report whether it came up cleanly.
#
#   ./build.sh test              headless (default)
#   ./build.sh test --window     open a GTK window, needs a local display
#   ./build.sh test --keep       leave the VM running afterwards
#
# Environment:
#   TIMEOUT=600      seconds to wait for boot before giving up
#   CPUS=32 MEM=16G  passed through to the VM
#   SETTLE=45        seconds to let the UI settle before the screenshot
#
# Exit status is 0 only if every check passes, so this is usable in a loop
# or from CI. Artefacts land in out/test/<timestamp>/.
#
set -uo pipefail

X86_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISK="$X86_ROOT/android-pc.img"
LOGCAT="$X86_ROOT/out/disk/logcat.txt"
KMSG="$X86_ROOT/out/disk/kmsg.txt"
QMP="$X86_ROOT/out/disk/qmp.sock"

TIMEOUT=${TIMEOUT:-600}
SETTLE=${SETTLE:-45}
# The guest retries its screencap until the screen has something on it, so
# this covers the retry window rather than a single capture.
CAPTURE_WAIT=${CAPTURE_WAIT:-90}
WINDOW=0
KEEP=0

for a in "$@"; do
    case "$a" in
        --window) WINDOW=1 ;;
        --keep)   KEEP=1 ;;
        -h|--help) sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else R=''; G=''; Y=''; B=''; N=''; fi

PASS=0; FAIL=0; WARN=0
pass() { printf '  %sPASS%s  %-34s %s\n' "$G" "$N" "$1" "${2:-}"; PASS=$((PASS+1)); }
fail() { printf '  %sFAIL%s  %-34s %s\n' "$R" "$N" "$1" "${2:-}"; FAIL=$((FAIL+1)); }
warn() { printf '  %sWARN%s  %-34s %s\n' "$Y" "$N" "$1" "${2:-}"; WARN=$((WARN+1)); }
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }

RESULTS="$X86_ROOT/out/test/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS"

cleanup() {
    if (( KEEP )); then
        info "leaving VM running (--keep); stop it with: pkill -f qemu-system-x86_64"
    else
        pkill -f qemu-system-x86_64 2>/dev/null
    fi
}
trap cleanup EXIT

# ------------------------------------------------------------- preflight ----
info "preflight"
[[ -f "$DISK" ]] || { fail "disk image" "missing $DISK -- run ./build.sh image"; exit 1; }
pass "disk image" "$(du -h "$DISK" | cut -f1)"

if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    pass "kvm accessible"
else
    fail "kvm accessible" "fix: sudo setfacl -m u:$USER:rw /dev/kvm (and usermod -aG kvm $USER)"
    exit 1
fi

# A stale VM holds the 5555 hostfwd and the new one refuses to start.
if pgrep -f qemu-system-x86_64 >/dev/null 2>&1; then
    warn "stale VM found" "killing it"
    pkill -f qemu-system-x86_64; sleep 3
fi

rm -f "$LOGCAT" "$KMSG"

# ----------------------------------------------------------------- boot ----
if (( WINDOW )); then
    [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || {
        fail "display" "--window needs DISPLAY; note SSH X-forwarding cannot do gl=on"; exit 1; }
    info "booting with GTK window (timeout ${TIMEOUT}s)"
    DISPLAY_MODE=auto "$X86_ROOT/build.sh" run -no-reboot > "$RESULTS/console.log" 2>&1 &
else
    info "booting headless (timeout ${TIMEOUT}s)"
    DISPLAY_MODE=none "$X86_ROOT/build.sh" run -no-reboot > "$RESULTS/console.log" 2>&1 &
fi

# ------------------------------------------------------- wait for markers ----
# "Boot is finished" comes from SurfaceFlinger; the launcher gaining top-resumed
# is the real sign the framework got all the way up.
deadline=$(( SECONDS + TIMEOUT ))
booted=0
while (( SECONDS < deadline )); do
    if grep -aq 'wm_on_top_resumed_gained_called.*launcher3' "$LOGCAT" 2>/dev/null; then
        booted=1; break
    fi
    if ! pgrep -f qemu-system-x86_64 >/dev/null 2>&1; then
        fail "VM alive" "exited early after ${SECONDS}s -- see $RESULTS/console.log"
        break
    fi
    sleep 5
done

if (( booted )); then
    pass "launcher resumed" "after ${SECONDS}s"
    info "letting the UI settle (${SETTLE}s)"
    sleep "$SETTLE"
else
    fail "launcher resumed" "not seen within ${TIMEOUT}s"
fi

# ------------------------------------------------ UI capture (screencap) ----
# The real picture of the UI, and the only one that works in the VM: the guest
# writes SurfaceFlinger's composited output to /dev/hvc2, which sidesteps the
# scanout path that virtio-gpu rejects. See doc/05-graphics.md 5.1.
#
# Two things make this fiddlier than reading a file. The guest starts its
# capture on an early trigger and retries until the screen has something on it,
# so we have to wait for it rather than sample once; and OVMF writes terminal
# escape sequences to the same character device during firmware init, so the
# PNG has to be extracted from its signature rather than used whole -- the file
# used to be exactly 33 bytes of "\e[2J\e[001;001H\e[=3h" and nothing else.
capture_raw="$X86_ROOT/out/disk/screencap.raw"
capture="$RESULTS/ui.png"

# The payload is base64 between markers, because /dev/hvc2 is a tty and its
# line discipline rewrites \n as \r\n -- which corrupted the raw PNG and even
# split its magic bytes. Decoding tolerates the \r the tty adds to every line,
# and the markers locate the payload amongst the OVMF escape sequences that
# firmware writes to the same port before Android boots.
decode() {
    python3 - "$1" "$2" 2>/dev/null <<'PY'
import base64, sys
raw, out = sys.argv[1], sys.argv[2]
d = open(raw, 'rb').read()
b = d.find(b'---PC-SCREENCAP-BEGIN---')
e = d.find(b'---PC-SCREENCAP-END---')
if b < 0 or e < 0:
    sys.exit(1)                      # not finished sending yet
payload = d[b + len(b'---PC-SCREENCAP-BEGIN---'):e]
img = base64.b64decode(b''.join(payload.split()), validate=False)
if not img.startswith(b'\x89PNG\r\n\x1a\n'):
    sys.exit(2)
open(out, 'wb').write(img)
PY
}

info "waiting for the guest UI capture (${CAPTURE_WAIT}s max)"
for ((i = 0; i < CAPTURE_WAIT; i += 2)); do
    decode "$capture_raw" "$capture" && break
    sleep 2
done

if [[ -s "$capture" ]]; then
    px=$(python3 - "$capture" 2>/dev/null <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
w, h = struct.unpack('>II', d[16:24])
print(f"{w}x{h}")
PY
)
    pass "UI captured" "$capture ${px:-} ($(du -h "$capture" | cut -f1))"
else
    fail "UI captured" "no PNG on /dev/hvc2 -- check 'pc-screencap' lines in logcat.txt"
fi

# ------------------------------------------------------------ screenshot ----
# Only meaningful headless: with a GTK window QEMU renders through the host
# display and screendump may not reflect what is on screen.
shot="$RESULTS/screen.ppm"
if [[ -S "$QMP" ]]; then
    python3 - "$QMP" "$shot" <<'PY' >/dev/null 2>&1
import socket, json, sys
sock, out = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sock)
f = s.makefile('rw'); f.readline()
def cmd(c):
    f.write(json.dumps(c) + '\n'); f.flush()
    while True:
        line = f.readline()
        if not line: return None
        r = json.loads(line)
        if 'return' in r or 'error' in r: return r
cmd({"execute": "qmp_capabilities"})
cmd({"execute": "screendump", "arguments": {"filename": out}})
PY
fi

# ---------------------------------------------------------------- checks ----
echo
info "results"

if [[ -s "$LOGCAT" ]]; then
    pass "logcat captured" "$(wc -l < "$LOGCAT") lines"
else
    fail "logcat captured" "empty -- virtio-console or the logcat service failed"
fi

check_zero() { # label, count, hint
    if [[ "${2:-0}" -eq 0 ]]; then pass "$1" "0"; else fail "$1" "$2 ${3:-}"; fi
}
# grep -c already prints the count; it just exits 1 when that count is zero,
# so swallow the status rather than echoing a second value.
c() { grep -ac "$1" "$LOGCAT" 2>/dev/null || true; }

check_zero "no native crashes"   "$(c 'Fatal signal')"
check_zero "no java fatals"      "$(c 'FATAL EXCEPTION')"
check_zero "no watchdog kills"   "$(c 'WATCHDOG KILLING')"
check_zero "no OOM"              "$(c 'OutOfMemoryError')"

if grep -aq 'Boot is finished' "$LOGCAT" 2>/dev/null; then
    pass "boot completed" "$(grep -ao 'Boot is finished ([0-9]* ms)' "$LOGCAT" | head -1)"
else
    fail "boot completed" "SurfaceFlinger never reported it"
fi

if grep -aq 'LOCKED_BOOT_COMPLETED' "$LOGCAT" 2>/dev/null; then
    pass "boot broadcast"
else
    fail "boot broadcast" "LOCKED_BOOT_COMPLETED not sent"
fi

# Any service started more than a handful of times is crash-looping.
loop=$(grep -aoE "starting service '[a-zA-Z0-9_.-]+'" "$LOGCAT" 2>/dev/null \
        | sort | uniq -c | sort -rn | head -1)
loopn=$(awk '{print $1}' <<<"$loop"); loopn=${loopn:-0}
if (( loopn <= 3 )); then
    pass "no service restart loops"
else
    fail "no service restart loops" "$(sed 's/^ *//' <<<"$loop")"
fi

# Composition: these are the virtio-gpu scanout symptoms.
fbfail=$(c 'could not create drm fb'); fbfail=${fbfail:-0}
if [[ "$fbfail" -eq 0 ]]; then
    pass "drm framebuffers created"
else
    warn "drm framebuffers created" "$fbfail failures -- expected under QEMU: virtio-gpu
       scans out only ARGB8888/XRGB8888 while SwiftShader renders ABGR8888.
       Not a regression, and not present on real hardware. See doc/05-graphics.md 5.1"
fi

if [[ -s "$shot" ]]; then
    colours=$(python3 - "$shot" <<'PY'
import sys
from collections import Counter
with open(sys.argv[1], 'rb') as f:
    if f.readline().strip() != b'P6': print(0); raise SystemExit
    while True:
        line = f.readline()
        if not line.startswith(b'#'): break
    f.readline()
    d = f.read()
print(len(Counter(d[i:i+3] for i in range(0, len(d), 3))))
PY
)
    if [[ "${colours:-0}" -gt 16 ]]; then
        pass "display renders" "$colours distinct colours"
    else
        warn "display renders" "${colours:-0} colours -- QMP screendump cannot read a GL
       scanout (it samples QEMU's DisplaySurface), so this says nothing about what is
       really on screen. Use DISPLAY_MODE=gtk or -vnc to look. 'UI captured' above is
       the meaningful check."
    fi
else
    warn "display renders" "no screenshot (normal with --window)"
fi

cp -f "$LOGCAT" "$RESULTS/logcat.txt" 2>/dev/null
cp -f "$KMSG"   "$RESULTS/kmsg.txt"   2>/dev/null

echo
printf '%s%d passed, %d failed, %d warnings%s\n' "$B" "$PASS" "$FAIL" "$WARN" "$N"
echo "artefacts: $RESULTS"
(( FAIL == 0 ))
