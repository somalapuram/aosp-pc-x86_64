#!/usr/bin/env bash
#
# Boot the pc_x86_64 disk image in QEMU/KVM configured as a GENERIC PC.
#
# This is deliberately not a Cuttlefish/crosvm launch. Every device here is
# chosen to match what real PC hardware presents, so the boot path, DRM/KMS
# stack and input/audio HALs are exercised the same way they will be on metal:
#
#   q35 + OVMF     real UEFI firmware, real GPT/ESP, real GRUB
#   nvme           real NVMe controller, not virtio-blk (see below)
#   virtio-vga-gl  real DRM/KMS node at /dev/dri/card0
#   intel-hda      real ALSA device (snd_hda_intel), not virtio-snd
#   usb-tablet/kbd real evdev input, not virtio-input
#
# The disk is NVMe rather than the faster virtio-blk for a hard reason, not
# just realism. Android init only creates /dev/block/by-name/* symlinks for
# partitions on the boot device, and when androidboot.boot_part_uuid is used
# it resolves that device via MMC / NVMe / SCSI matchers only
# (devices.cpp GetBlockDeviceInfo). virtio-blk matches none of them, so
# info.str comes back empty, boot_devices becomes {""}, no by-name symlinks
# are created, and first-stage mount fails with:
#     init: Boot device  found via partition UUID      <- note the empty name
#     [libfs_mgr] Failed to open '/dev/block/by-name/system'
# NVMe (and AHCI, which presents as SCSI) resolve correctly and are what real
# PC hardware uses anyway.
#
# See doc/02-host-setup.md section 3.
#
set -euo pipefail

X86_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISK="${DISK:-$X86_ROOT/android-pc.img}"
VARS="$X86_ROOT/out/disk/OVMF_VARS.fd"

CPUS=${CPUS:-8}
MEM=${MEM:-8G}

# Logcat capture, over virtio-console (/dev/hvc0 in the guest).
#
# Userspace crash reasons live in logcat, not dmesg -- init only reports
# "Service 'x' received SIGABRT" while the actual cause is invisible on a
# headless boot. adb is not usable yet (adbd starts from the USB trigger and
# QEMU has no device-mode controller), and `logcat -f` fails on a character
# device because -f performs log rotation, which needs a seekable file. A
# shell redirect avoids that.
#
# This deliberately does NOT use a second 16550 UART. Every byte written to an
# emulated 16550 is a port write and therefore a VM exit; a full boot's logcat
# is 120k+ lines, which cost enough exits to starve the guest and trip
# Android's watchdog (WATCHDOG KILLING SYSTEM PROCESS: Blocked in handler on
# main thread for 67s) with no real deadlock. virtio-console moves the same
# data over a virtqueue at negligible cost.
#
# Two virtio-console ports are exposed:
#   hvc0 -> kmsg    (kernel console; GRUB passes console=hvc0)
#   hvc1 -> logcat  (init starts a logcat redirect onto it)
#
# The kernel console is on virtio-console rather than ttyS0 for the same
# reason: at loglevel=7 a permissive boot emits thousands of avc denials, and
# pushing those through the UART is slow enough to distort boot timing. Over
# virtio both streams can stay fully verbose.
LOGCAT_FILE=${LOGCAT_FILE:-$X86_ROOT/out/disk/logcat.txt}
KMSG_FILE=${KMSG_FILE:-$X86_ROOT/out/disk/kmsg.txt}
# QMP control socket. Lets the harness capture the guest framebuffer with
# 'screendump' -- the only way to confirm the UI actually renders when running
# headless, since logcat can only show that the launcher was resumed.
# Third virtio-console port, carrying a PNG screenshot out of the guest.
#
# The virtio-gpu scanout limitation keeps the host-side framebuffer blank, and
# adb over TCP is refused despite adbd listening, so neither the QMP screendump
# nor `adb shell screencap` can show what Android actually drew. screencap
# reads SurfaceFlinger's composited output directly, so writing it to a
# character device sidesteps both: whatever lands here is the real UI.
SCREENCAP_FILE=${SCREENCAP_FILE:-$X86_ROOT/out/disk/screencap.raw}
rm -f "$SCREENCAP_FILE"
QMP_SOCK=${QMP_SOCK:-$X86_ROOT/out/disk/qmp.sock}
rm -f "$QMP_SOCK"
mkdir -p "$(dirname "$LOGCAT_FILE")"
# 'gtk' needs a local display; fall back to headless with serial only.
#
# DISPLAY_MODE=vnc is the one to use over SSH -- MobaXterm, PuTTY and friends.
# X11 forwarding cannot carry gtk,gl=on: there is no direct rendering over the
# wire, so QEMU reports
#     libEGL warning: DRI3 error: Could not get DRI3 device
# and you get no accelerated output. VNC sidesteps that: QEMU renders locally
# with egl-headless and serves finished frames, which is exactly what a remote
# client wants.
#
# Bound to 127.0.0.1 deliberately. QEMU's VNC has no password here, and
# binding it to every interface would expose an unauthenticated view of the
# machine to the network. Reach it through the SSH tunnel you already have.
DISPLAY_MODE=${DISPLAY_MODE:-auto}
VNC_DISPLAY=${VNC_DISPLAY:-1}

[[ -f "$DISK" ]] || { echo "no disk image: $DISK  (run ./build.sh image)" >&2; exit 1; }

# The adb host-forward. Overridable because 5555 is the default for every
# Android emulator on the machine, not just this one:
#     ADB_PORT=5585 ./build.sh run
ADB_PORT="${ADB_PORT:-5555}"

# A VM left running from a previous session holds the hostfwd, and QEMU then
# refuses to start with a message that names the port and not the cause:
#     qemu-system-x86_64: -netdev user,id=n0,hostfwd=tcp::5555-:5555:
#         Could not set up host forwarding rule 'tcp::5555-:5555'
# ./build.sh test kills stale VMs itself; this path did not, so 'run' simply
# failed and left you guessing. Say what is wrong and how to fix it.
#
# Match OUR disk image, not the qemu binary. An Android Studio AVD is also a
# qemu-system-x86_64 process, so the old check reported "a VM is already
# running" for an unrelated emulator and told you to pkill it -- advice that
# would have killed someone's running AVD to free a port this script can simply
# be told to change.
if pgrep -f "[q]emu-system-x86_64.*$(basename "$DISK")" >/dev/null 2>&1; then
    echo "A VM is already running on $(basename "$DISK") (pid $(pgrep -f "[q]emu-system-x86_64.*$(basename "$DISK")" | head -1))." >&2
    echo "It holds the $ADB_PORT host-forward, so this one cannot start." >&2
    echo "Stop it with:  pkill -f 'qemu-system-x86_64.*$(basename "$DISK")'" >&2
    exit 1
fi

# Someone else's emulator on the same port is a different problem with a
# different fix, so say so rather than blaming a stale VM of ours.
if command -v ss >/dev/null 2>&1 && ss -ltn "sport = :$ADB_PORT" 2>/dev/null | grep -q ":$ADB_PORT"; then
    echo "Port $ADB_PORT is already in use by another process (an Android Studio AVD" >&2
    echo "uses 5555 too). Pick a free one:  ADB_PORT=5585 ./build.sh run" >&2
    exit 1
fi

# OVMF vars must be writable per-VM. The 4M build is the current Debian/Ubuntu
# layout; fall back to the legacy name.
mkdir -p "$(dirname "$VARS")"
if [[ ! -f "$VARS" ]]; then
    for src in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
        [[ -f "$src" ]] && { cp "$src" "$VARS"; break; }
    done
fi
[[ -f "$VARS" ]] || { echo "OVMF vars not found (apt install ovmf)" >&2; exit 1; }

CODE=""
for src in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
    [[ -f "$src" ]] && { CODE="$src"; break; }
done
[[ -n "$CODE" ]] || { echo "OVMF code not found (apt install ovmf)" >&2; exit 1; }

ACCEL=()
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ACCEL=(-machine q35,accel=kvm -cpu host)
else
    echo "warning: /dev/kvm not accessible -- falling back to TCG (very slow)" >&2
    echo "         fix with: sudo usermod -aG kvm \$USER   (then log out and back in)" >&2
    ACCEL=(-machine q35 -cpu max)
fi

# Graphics.
#
# The guest UI reaches the screen. This took three fixes, all in patches/:
#
#   1. drm/virtio accepts ABGR8888. It advertised only HOST_XRGB8888 and
#      rejected everything else from ADDFB2 with ENOENT, so Android -- which
#      composes into RGBA_8888 (DRM_FORMAT_ABGR8888) -- could never scan out.
#      The errno reads as a missing GEM handle rather than a refused format,
#      which is why it was misdiagnosed for a long time.
#
#   2. minigbm creates its virgl context up front. On a context-init host the
#      kernel does not create one in gem_object_open(), so no buffer was ever
#      attached and every TRANSFER_TO_HOST was refused by the host with
#      "Illegal resource N". Allocation, commits and presents all succeeded --
#      the host just never received any pixels.
#
#   3. minigbm forces linear buffers (DRV_PC_FORCE_LINEAR), because the
#      renderer is SwiftShader on the CPU and tiled buffers cannot be mapped.
#
# BEWARE the QMP screendump: it captures QEMU's DisplaySurface, which is NOT
# updated for a GL/dmabuf scanout, so it reports an all-black screen no matter
# what is really being displayed. The cursor plane takes the non-GL path and
# does show up, which makes the capture look plausible and wrong -- a black
# frame with a lone cursor. Use a real display backend to see the guest:
#
#     DISPLAY_MODE=gtk ./build.sh run          # local display
#     ./build.sh run -vnc :1                   # then connect a VNC client
#
# ./build.sh test still captures the UI from inside the guest with screencap,
# which is independent of scanout and works headlessly.
#
# GPU=plain (virtio-vga without virgl) remains broken for an unrelated reason:
# RenderEngine::validateOutputBufferUsage() is a LOG_ALWAYS_FATAL_IF on
# USAGE_HW_RENDER, so SurfaceFlinger aborts with "output buffer not gpu
# writeable". Kept only for experimentation.
#
# Guest display resolution.
#
# 2560x1600 by default -- twice the old 1280x800 in each axis. Note this is
# only half the story: Android sizes its UI in dp, so resolution alone does not
# change how much fits on screen. dp width = xres / (ro.sf.lcd_density / 160),
# which at density 240 gives
#
#     1280x800   ->  853 x 533 dp    (sw533dp, phone-ish layout)
#     2560x1600  -> 1706 x 1066 dp   (sw1066dp, large-tablet layout)
#
# so doubling the resolution at a fixed density also switches Android to its
# large-screen layouts and makes everything look smaller. To scale the picture
# up while keeping the same layout, double ro.sf.lcd_density to 480 in
# device.mk as well -- that is a build property, so it needs a rebuild, whereas
# XRES/YRES here take effect on the next boot.
#
# The default is now measured rather than assumed. 2560x1600 is the panel of
# the real target machine, and hardcoding it made the QEMU window unusable on
# any host screen smaller than that: GTK asks for a window the size of the
# guest framebuffer, the window manager refuses and shrinks it, and the result
# is a small window showing a large-tablet layout, which is both tiny and
# clipped. Nothing in the guest is wrong; there is just nowhere to put it.
#
# So ask the host how big its screen is and fit the guest inside it. The
# detection reads DISPLAY, it never sets it -- picking a display is the
# session's business, and this script has been wrong about it twice already.
#
# Only the geometry is taken from the host; the aspect ratio is left alone by
# scaling both axes with the same factor, so the guest stays 16:10 and Android
# keeps a sensible dp size. 90% leaves room for titlebars, panels and docks,
# and the result is rounded down to a multiple of 8 because virtio-gpu is
# happier with aligned strides.
#
# Explicit XRES/YRES still win, and the fallback when nothing can be measured
# is 1920x1200: 16:10, fits a 1080p screen once scaled, and at density 240 is
# 1280x800dp, so still a large-screen layout rather than a phone one.
detect_host_screen() {
    local geom=""
    if [[ -n "${DISPLAY:-}" ]] && command -v xdpyinfo >/dev/null 2>&1; then
        geom=$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}')
    fi
    if [[ -z "$geom" && -n "${DISPLAY:-}" ]] && command -v xrandr >/dev/null 2>&1; then
        geom=$(xrandr 2>/dev/null | awk '/\*/ {print $1; exit}')
    fi
    if [[ -z "$geom" ]] && command -v wlr-randr >/dev/null 2>&1; then
        geom=$(wlr-randr 2>/dev/null | awk '/current/ {print $1; exit}')
    fi
    [[ "$geom" =~ ^([0-9]+)x([0-9]+)$ ]] || return 1
    # Trailing newline matters: read returns non-zero when it hits EOF without
    # one, even though it has already assigned the variables, so the caller's
    # `if read ...` would take the failure branch every time and silently fall
    # back to the default. That is exactly what it did until this was tested.
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

if [[ -z "${XRES:-}${YRES:-}" ]]; then
    if read -r HOST_W HOST_H < <(detect_host_screen) && (( HOST_W > 0 && HOST_H > 0 )); then
        # Fill the host screen, keeping ITS aspect ratio.
        #
        # The first attempt at this forced 16:10 to match the target laptop's
        # panel and took 90%, which on a 16:9 host produced 1552x968 -- smaller
        # than the window the old hardcoded 2560x1600 ended up with once the
        # window manager had shrunk it, so the change made the thing it was
        # meant to fix worse. Matching the target's aspect is not worth losing
        # a fifth of the screen: the guest is being looked at here, not
        # measured, and pclauncher lays out responsively.
        #
        # 95% rather than 100% because the window has a titlebar and the host
        # may have a panel or dock; a window taller than the workarea gets
        # shrunk by the WM, which is the failure being avoided. Aligned to 8
        # for stride.
        XRES=$(( HOST_W * 95 / 100 / 8 * 8 ))
        YRES=$(( HOST_H * 95 / 100 / 8 * 8 ))
        echo "guest display ${XRES}x${YRES} (host screen ${HOST_W}x${HOST_H}; FULLSCREEN=1 for the whole screen)" >&2
    else
        XRES=1920
        YRES=1200
        echo "guest display ${XRES}x${YRES} (host screen not detected; override with XRES/YRES)" >&2
    fi
fi
XRES=${XRES:-1920}
YRES=${YRES:-1200}

# Blob resources: let the guest and host SHARE buffers instead of copying.
#
# Without this the guest negotiates "-resource_blob" and every single frame is
# copied guest->host through the virtqueue with a TRANSFER_TO_HOST round trip.
# At 2560x1600 that is 16.4 MB per frame -- about 1 GB/s of memcpy at 60fps --
# on a serialised path, which is why the VM feels sluggish while six of its
# eight vCPUs sit idle. It is not short of CPU; it is waiting on copies.
#
# blob=on needs shareable guest memory, hence the memfd backend.
#
# DEFAULT OFF: it crashes QEMU 10.2.1, and it never bought anything measurable.
#
# The theory above is sound but never showed up in a measurement: enabling it
# made no difference we could detect, apparently because Mesa's virgl already
# keeps the heavy buffers host-side. What it did do is segfault the host, three
# times, always identically:
#
#     qemu-system-x86[189101]: segfault at 0 ip ...  error 4 in libc.so.6[1aa362]
#
#     #0  __strcmp_evex           rsi = 0x0
#     #1  cpr_delete_fd ()
#     #2  qemu_ram_free ()        <- virtio-gpu worker thread, not the main loop
#
# qemu_ram_free() does, with no NULL check:
#
#     mov  0x10(%r12),%rdi        ; block->mr
#     call <memory_region_name>
#     mov  %rax,%rdi              ; name -- NULL here
#     call <cpr_delete_fd>        ; -> strcmp(elem->name, NULL)
#
# The block being freed is a 1 MiB RAMBlock with an empty idstr -- a
# host-visible blob resource -- and its MemoryRegion has a NULL QOM parent
# (Object::parent at mr+0x20 reads 0). memory_region_name() falls back to
# object_get_canonical_path_component(), which returns NULL for an unparented
# object, so the name is NULL and cpr_delete_fd() walks its list strcmp'ing
# against it. That is a QEMU bug, not a configuration error.
#
# It needs BOTH halves of what this block turns on, which is why it appeared
# only once Mesa started driving virgl for real:
#
#   - blob=on           so blob resources get allocated and freed at all;
#                       SwiftShader never created one.
#   - memory-backend-memfd
#                       so cpr_state.fds is non-empty. cpr_delete_fd's first
#                       act is 'test %rbx,%rbx; je <ret>' on the list head, so
#                       with an empty list the NULL name is never dereferenced.
#
# Set BLOB=on to opt back in once the host QEMU carries the fix.
BLOB=${BLOB:-off}
MEMOPTS=()
BLOBOPT=""
if [[ "$BLOB" == "on" ]]; then
    MEMOPTS=(-object "memory-backend-memfd,id=vmem,size=$MEM,share=on"
             -machine memory-backend=vmem)
    BLOBOPT=",blob=on,hostmem=1G"
fi

GPU=${GPU:-virgl}
GFX=()

# Start fullscreen on request: FULLSCREEN=1 ./build.sh run
#
# Defined here, before the GPU branch, because it has to be set on every path.
# It was first written just inside `if [[ "$GPU" == "plain" ]]`, which GPU
# defaults away from, so FS stayed unset, "${FS[@]}" expanded to nothing, and
# -full-screen never reached qemu however the variable was exported. The
# environment was reaching the process the whole time -- FULLSCREEN=1 was
# visible in /proc/<pid>/environ -- which is what made it look like qemu was
# ignoring the flag rather than never being given it.
FS=()
[[ -n "${FULLSCREEN:-}" ]] && FS=(-full-screen)

# A second, blank disk: DISK2=/path/to.img ./build.sh run
#
# Exists to test the installer without a machine to lose. It attaches as a
# second nvme, so the guest sees nvme0n1 (this image, booted) and nvme1n1
# (empty) -- both non-removable, which is the case that actually matters,
# because "not removable" is most of how pc_install.sh decides what to erase.
# A removable second disk would be excluded and would prove nothing.
DISK2OPT=()
if [[ -n "${DISK2:-}" ]]; then
    [[ -f "$DISK2" ]] || { echo "DISK2=$DISK2 does not exist" >&2; exit 1; }
    DISK2OPT=(-drive "file=$DISK2,format=raw,if=none,id=disk1"
              -device nvme,drive=disk1,serial=androidpc1)
    echo "second disk: $DISK2 ($(( $(stat -c %s "$DISK2") / 1024 / 1024 )) MiB) as nvme1n1" >&2
fi
if [[ "$GPU" == "plain" ]]; then
case "$DISPLAY_MODE" in
        none|auto) GFX=(-device virtio-vga,xres=$XRES,yres=$YRES -display none) ;;
        *)         GFX=(-device virtio-vga,xres=$XRES,yres=$YRES -display "$DISPLAY_MODE") ;;
    esac
else
# Resolve 'auto' to a concrete mode first, so the vnc branch below -- and the
# connection instructions it prints -- is shared rather than duplicated.
#
# A set DISPLAY is NOT on its own a reason to open a GTK window: over SSH X11
# forwarding (MobaXterm, PuTTY) it is a forwarded display, and gtk,gl=on is the
# wrong answer there twice over. gl=on wants a local GL context, and GTK cannot
# find a GdkMonitor for a window it does not really own, so QEMU's per-frame
# refresh-rate query fails on every frame:
#
#     qemu: Gdk: gdk_monitor_get_refresh_rate: assertion 'GDK_IS_MONITOR (monitor)' failed
#
# Harmless in itself -- a g_return_if_fail that yields a 0 refresh rate -- but
# it floods stdout, which -serial mon:stdio shares, so it interleaves with and
# chops up the guest console:
#
#     [    6.699643] servicemanager: Notifying media.codeclist.genqemu: Gdk: ...
#     erator they don't (previously: do) have clients ...
#
# VNC is the right remote answer anyway: QEMU renders with egl-headless on the
# host GPU and ships finished frames, instead of pushing X11 traffic per frame.
if [[ "$DISPLAY_MODE" == auto ]]; then
    # If there is a display of any kind, show the window on it. That is the
    # whole rule.
    #
    # This has been wrong twice, in both directions, and both times by trying to
    # be clever about WHICH display it is. First it keyed off SSH_CONNECTION and
    # sent every ssh session to VNC -- which took away the monitor attached to
    # this machine, since a graphical session on seat0 gives an sshed-in shell a
    # perfectly usable local display. Then it keyed off the shape of DISPLAY and
    # sent forwarded displays to VNC instead -- which took away the MobaXterm
    # window, and that works too: qemu -display gtk on localhost:10.0 opens a
    # window on the client's X server, gl=on included.
    #
    # Both were solving a problem the user did not have. VNC is worth having for
    # a headless host or a slow link, but it is an extra client and an extra
    # tunnel every time, so it is opt-in: DISPLAY_MODE=vnc.
    if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        DISPLAY_MODE=gtk
    else
        DISPLAY_MODE=none
    fi
fi



case "$DISPLAY_MODE" in
    none) GFX=(-device virtio-vga-gl,xres=$XRES,yres=$YRES$BLOBOPT -display egl-headless) ;;
    # gl=on is not optional: the plain GTK path takes the non-GL scanout, which
    # is the black-screen-with-a-cursor failure described in doc/05-graphics.md.
    # No zoom-to-fit. It reads like the option that makes the window bigger and
    # does the reverse: the window keeps the size it was created at and the
    # guest is scaled DOWN into it. Both halves were measured separately here.
    # With video=Virtual-1:1600x900 fixing the guest, fbcon reported
    # "colour frame buffer device 200x56" -- 200 columns of 8px by 56 rows of
    # 16px, exactly 1600x900 -- while xwininfo still showed the window at
    # 640x507. The guest was right and the window was ignoring it.
    #
    # Without it GTK sizes the window to the guest's scanout, which is the
    # behaviour wanted: fix the mode, get a window that size. Resolution is
    # therefore set by video= in mkdisk.sh, not here; xres/yres below only
    # supply the EDID preferred mode, which nothing on this guest acts on.
    gtk)  GFX=(-device virtio-vga-gl,xres=$XRES,yres=$YRES$BLOBOPT
               -display gtk,gl=on) ;;
    vnc)  GFX=(-device virtio-vga-gl,xres=$XRES,yres=$YRES$BLOBOPT
               -display egl-headless -vnc "127.0.0.1:$VNC_DISPLAY")
          cat >&2 <<VNCMSG

  VNC ready on 127.0.0.1:$((5900 + VNC_DISPLAY))  (display :$VNC_DISPLAY)

  From MobaXterm (or any SSH client), forward the port:
      ssh -L $((5900 + VNC_DISPLAY)):127.0.0.1:$((5900 + VNC_DISPLAY)) $USER@$(hostname)
  then point a VNC client at:
      localhost:$((5900 + VNC_DISPLAY))

  MobaXterm has a VNC client built in: Sessions -> VNC, host localhost,
  port $((5900 + VNC_DISPLAY)). Tunnelling is required -- the server is bound to
  loopback on purpose, because it has no password.

VNCMSG
          ;;
    *)    GFX=(-device virtio-vga-gl,xres=$XRES,yres=$YRES$BLOBOPT -display "$DISPLAY_MODE") ;;
esac
fi

# Drop GTK's per-frame GdkMonitor assertion, and nothing else.
#
# Over forwarded X, GTK cannot find a GdkMonitor for a window it does not really
# own, so QEMU's refresh-rate query fails on every single frame:
#     qemu: Gdk: gdk_monitor_get_refresh_rate: assertion 'GDK_IS_MONITOR (monitor)' failed
# The window itself is fine -- this is a g_return_if_fail yielding a 0 refresh
# rate -- but thousands of them bury the guest console.
#
# They go to stderr while '-serial mon:stdio' puts the guest console on stdout,
# so one grep on stderr alone removes the flood and keeps everything else:
# real QEMU errors still print, and the console is untouched. Matching the exact
# assertion text rather than silencing stderr wholesale is deliberate -- a VM
# that fails to start must still say why.
if [[ "$DISPLAY_MODE" == gtk ]]; then
    exec 2> >(grep --line-buffered -v \
        "gdk_monitor_get_refresh_rate: assertion 'GDK_IS_MONITOR (monitor)' failed" >&2)
fi

exec qemu-system-x86_64 \
    "${ACCEL[@]}" \
    "${MEMOPTS[@]}" \
    -smp "$CPUS" -m "$MEM" \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$CODE" \
    -drive if=pflash,format=raw,unit=1,file="$VARS" \
    -drive file="$DISK",format=raw,if=none,id=disk0 \
    -device nvme,drive=disk0,serial=androidpc0 \
    "${DISK2OPT[@]}" \
    "${GFX[@]}" \
    "${FS[@]}" \
    -device intel-hda -device hda-duplex \
    -device virtio-net-pci,netdev=n0 \
    -netdev user,id=n0,hostfwd=tcp::${ADB_PORT}-:5555 \
    -device qemu-xhci -device usb-tablet -device usb-kbd \
    -serial mon:stdio \
    -qmp "unix:$QMP_SOCK,server,nowait" \
    -device virtio-serial-pci,id=vser0 \
    -chardev "file,id=kmsgchr,path=$KMSG_FILE" \
    -device virtconsole,chardev=kmsgchr,name=kmsg \
    -chardev "file,id=logcatchr,path=$LOGCAT_FILE" \
    -device virtconsole,chardev=logcatchr,name=logcat \
    -chardev "file,id=capchr,path=$SCREENCAP_FILE" \
    -device virtconsole,chardev=capchr,name=screencap \
    "$@"
