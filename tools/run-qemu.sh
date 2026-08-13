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
SCREENCAP_FILE=${SCREENCAP_FILE:-$X86_ROOT/out/disk/screencap.png}
rm -f "$SCREENCAP_FILE"
QMP_SOCK=${QMP_SOCK:-$X86_ROOT/out/disk/qmp.sock}
rm -f "$QMP_SOCK"
mkdir -p "$(dirname "$LOGCAT_FILE")"
# 'gtk' needs a display; fall back to headless with serial only.
DISPLAY_MODE=${DISPLAY_MODE:-auto}

[[ -f "$DISK" ]] || { echo "no disk image: $DISK  (run ./build.sh image)" >&2; exit 1; }

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
# KNOWN LIMITATION: the guest UI does not reach the screen under either
# virtio-gpu mode. Android itself boots cleanly regardless -- zero crashes,
# launcher resumed, LOCKED_BOOT_COMPLETED -- but the framebuffer stays blank.
# The two modes fail on opposite sides of the same constraint:
#
#   GPU=virgl (default, virtio-vga-gl + egl-headless)
#     SurfaceFlinger gets GPU-writeable buffers and composes happily, but
#     drm_hwcomposer cannot turn them into DRM framebuffers:
#         drmhwc: could not create drm fb -2   (ENOENT from drmModeAddFB2)
#         drmhwc: Failed to create AtomicCommitArgs for frame composition.
#         SurfaceFlinger: present failed ...: BAD_DISPLAY (2)
#
#   GPU=plain (virtio-vga, no virgl)
#     Framebuffer creation succeeds -- zero drm fb errors -- but SurfaceFlinger
#     aborts immediately:
#         F SurfaceFlinger: output buffer not gpu writeable
#     RenderEngine::validateOutputBufferUsage() is a LOG_ALWAYS_FATAL_IF on
#     USAGE_HW_RENDER, so there is no property to relax it.
#
# ROOT CAUSE. An earlier version of this comment blamed minigbm's scanout
# flags, quoting the "Virtio primary plane only allows this format" branch of
# virtgpu_virgl.c. That was wrong twice over: the quoted branch is the non-3D
# path, not the one virgl takes, and the guest log contains no "Strip scanout"
# messages at all -- so the RGB formats keep BO_USE_SCANOUT. Allocation is not
# where this fails.
#
# It fails in the guest kernel, in drivers/gpu/drm/virtio/virtgpu_display.c:
#
#     if (mode_cmd->pixel_format != DRM_FORMAT_HOST_XRGB8888 &&
#         mode_cmd->pixel_format != DRM_FORMAT_HOST_ARGB8888)
#             return ERR_PTR(-ENOENT);
#
# virtio-gpu accepts exactly two framebuffer formats. SurfaceFlinger composes
# into RGBA_8888, which minigbm maps to DRM_FORMAT_ABGR8888, so every ADDFB2 is
# rejected. The -2 is that ENOENT, which reads like a missing GEM handle rather
# than a refused format -- the reason this was misdiagnosed.
#
# The obvious fix does not work. SurfaceFlinger's client target format is
# hardcoded in RenderSurface::initialize(), and the only override is HWC3's
# ClientTargetProperty, which drm_hwcomposer does not implement. Implementing
# it (reporting BGRA_8888 -> DRM_FORMAT_ARGB8888, which virtio accepts) does
# reach SurfaceFlinger -- it starts composing in format 5 -- and then it dies:
#     F SurfaceFlinger: Failed to create a valid texture.
#                       [1280,800] isWriteable:1 format:5
#     E AndroidRuntime: Failed to initialize display event receiver. status=-32
# 119 SIGABRTs, no boot. SwiftShader cannot render into BGRA_8888.
#
# So the constraint is two-sided and cannot be satisfied by a format choice:
# virtio-gpu scans out only ARGB8888/XRGB8888, and the software renderer only
# produces ABGR8888. Nothing in between can be both.
#
# The fix is Mesa (doc/05-graphics.md section 4). A real GL driver renders into
# whichever format the display needs, and the question disappears. Until then
# the VM boots correctly with a blank screen, and the display is verified on
# real hardware instead, where i915 and amdgpu take ABGR8888 happily.
#
# This is also why Cuttlefish does not hit it: crosvm uses gfxstream rather
# than virgl+KMS.
#
# Tried and rejected: ro.surface_flinger.default_composition_pixel_format (it
# only feeds RenderEngine's EGL config and getCompositionPreference, not the
# client target buffer); blob=on with hostmem (no change); patching
# drm_hwcomposer so the test_only path retries a failed seamless commit with
# ALLOW_MODESET (the retry fails identically).
#
# Default stays virgl because that combination boots cleanly. GPU=plain is kept
# for experimentation and to make the trade-off reproducible.
GPU=${GPU:-virgl}
GFX=()
if [[ "$GPU" == "plain" ]]; then
    case "$DISPLAY_MODE" in
        none|auto) GFX=(-device virtio-vga,xres=1280,yres=800 -display none) ;;
        *)         GFX=(-device virtio-vga,xres=1280,yres=800 -display "$DISPLAY_MODE") ;;
    esac
else
case "$DISPLAY_MODE" in
    none) GFX=(-device virtio-vga-gl,xres=1280,yres=800 -display egl-headless) ;;
    auto) if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
              GFX=(-device virtio-vga-gl -display gtk,gl=on)
          else
              GFX=(-device virtio-vga-gl,xres=1280,yres=800 -display egl-headless)
          fi ;;
    *)    GFX=(-device virtio-vga-gl -display "$DISPLAY_MODE") ;;
esac
fi

exec qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -smp "$CPUS" -m "$MEM" \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$CODE" \
    -drive if=pflash,format=raw,unit=1,file="$VARS" \
    -drive file="$DISK",format=raw,if=none,id=disk0 \
    -device nvme,drive=disk0,serial=androidpc0 \
    "${GFX[@]}" \
    -device intel-hda -device hda-duplex \
    -device virtio-net-pci,netdev=n0 \
    -netdev user,id=n0,hostfwd=tcp::5555-:5555 \
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
