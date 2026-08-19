#!/usr/bin/env bash
#
# The QEMU command for the pc_x86_64 image, written out plainly so it can be
# run, read and edited by hand. No wrapper, no auto-detection, nothing set for
# you -- in particular DISPLAY is left exactly as your shell has it.
#
#   ./qemu.sh                 boot it
#   ./qemu.sh -no-reboot      ...with any extra QEMU args appended
#
# Nothing else may be running: the guest's adb is forwarded to host port 5555,
# and a second VM fails to start while the first holds it.
#     pkill -f qemu-system-x86_64
#
# The two lines that decide where the picture goes are marked DISPLAY below.
# Swap them for one of:
#     -display gtk,gl=on                       window on $DISPLAY (default)
#     -display egl-headless -vnc 127.0.0.1:1   no window; VNC on port 5901
#     -display none                            headless, serial console only
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK="$HERE/android-pc.img"
OUT="$HERE/out/disk"

[[ -f "$DISK" ]] || { echo "no disk image at $DISK -- run ./build.sh image" >&2; exit 1; }
mkdir -p "$OUT"

# OVMF vars are per-VM and must be writable; seed once from the system copy.
[[ -f "$OUT/OVMF_VARS.fd" ]] || cp /usr/share/OVMF/OVMF_VARS_4M.fd "$OUT/OVMF_VARS.fd"

exec qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -smp 8 \
    -m 8G \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,unit=1,file="$OUT/OVMF_VARS.fd" \
    -drive file="$DISK",format=raw,if=none,id=disk0 \
    -device nvme,drive=disk0,serial=androidpc0 \
    -device virtio-vga-gl,xres=2560,yres=1600 \
    -display gtk,gl=on \
    -device intel-hda \
    -device hda-duplex \
    -device virtio-net-pci,netdev=n0 \
    -netdev user,id=n0,hostfwd=tcp::5555-:5555 \
    -device qemu-xhci \
    -device usb-tablet \
    -device usb-kbd \
    -serial mon:stdio \
    -qmp unix:"$OUT/qmp.sock",server,nowait \
    -device virtio-serial-pci,id=vser0 \
    -chardev file,id=kmsgchr,path="$OUT/kmsg.txt" \
    -device virtconsole,chardev=kmsgchr,name=kmsg \
    -chardev file,id=logcatchr,path="$OUT/logcat.txt" \
    -device virtconsole,chardev=logcatchr,name=logcat \
    -chardev file,id=capchr,path="$OUT/screencap.raw" \
    -device virtconsole,chardev=capchr,name=screencap \
    "$@"
