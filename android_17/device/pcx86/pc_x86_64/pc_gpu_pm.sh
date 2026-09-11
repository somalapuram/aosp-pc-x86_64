#!/vendor/bin/sh
#
# Let an unused discrete GPU sleep.
#
# Linux defaults every PCI device to power/control=on, i.e. runtime PM disabled.
# On a desktop distro a udev rule flips Optimus-style discrete GPUs to "auto" so
# they can enter D3 when nothing is using them. Android ships no such rule, so
# nothing ever sets it and the card stays awake for the life of the boot.
#
# Measured on the HP laptop, booted on the INTEL entry, with the dGPU doing no
# rendering whatsoever (GLES: Intel, drm.gpu.vendor_name=i915):
#
#     card1 power_state             D0
#     card1 runtime_status          active
#     card1 power/control           on
#     card1 runtime_suspended_time  0      <- never suspended, all boot
#
# An idle RTX A500 held in D0 is several watts for nothing.
#
# "auto" does not disable the GPU. The driver keeps it powered while anything
# holds it open, and PRIME wakes it on demand, so the render-offload entry is
# unaffected beyond idling cheaply between uses.
#
# The card is chosen the same way pc_select_egl.sh picks its offload target,
# and for the same reason: the discrete GPU is the one that renders but drives
# no display.
#   - has a render node        (it is a GPU, not simpledrm)
#   - boot_vga != 1            (not the built-in adapter)
#   - no connected connector   (muxless: the dGPU has no outputs at all)
# Anything driving the panel is left alone -- suspending the scanout GPU is not
# something to do casually.

log() { echo "pc-gpu-pm: $*" > /dev/kmsg 2>/dev/null; }

for c in /sys/class/drm/card[0-9]; do
    [ -e "$c" ] || continue

    ls "$c/device/drm/" 2>/dev/null | grep -q '^renderD' || continue
    [ "$(cat "$c/device/boot_vga" 2>/dev/null)" = "1" ] && continue

    drives_display=0
    for conn in "$c"-*; do
        [ -e "$conn/status" ] || continue
        if [ "$(cat "$conn/status" 2>/dev/null)" = "connected" ]; then
            drives_display=1
            break
        fi
    done
    [ "$drives_display" = 0 ] || continue

    ctl="$c/device/power/control"
    [ -w "$ctl" ] || { log "$(basename "$c"): $ctl not writable"; continue; }

    echo auto > "$ctl" 2>/dev/null
    log "$(basename "$c"): power/control=$(cat "$ctl" 2>/dev/null) status=$(cat "$c/device/power/runtime_status" 2>/dev/null)"
done
