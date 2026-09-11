#!/system/bin/sh
#
# Choose the GL implementation from the DRM driver actually present.
#
# ro.hardware.egl is a single build property applied to every device, but this
# image has to run on two very different ones and they need different answers:
#
#   virtio-gpu (QEMU)  -> mesa   Mesa's virgl driver forwards GL to the host
#                                GPU. Real acceleration; SwiftShader is not
#                                involved at all.
#   i915 / xe          -> mesa   Mesa's iris driver. Real acceleration on the
#                                Intel GPU; SwiftShader is not involved.
#   amdgpu / nouveau   -> mesa   Both have a gallium driver here now. Mesa is
#                                built gallium-drivers=iris,radeonsi,nouveau,
#                                virgl,softpipe -- confirmed in
#                                out/mesa/build-x86_64/meson-info/intro-buildoptions.json
#                                and by nm -a on the shipped libgallium_dri.so.
#                                (strings(1) cannot answer this: the
#                                DRM_DRIVER_DESCRIPTOR_STUB macro emits a
#                                pipe_<driver>_create_screen symbol for drivers
#                                that were NOT built.)
#   radeon             -> mesa   Pre-GCN. r300/r600 are not built, so this ends
#                                up on softpipe rather than a real driver.
#
# Getting this wrong is not subtle. Point real hardware at a Mesa with no
# driver for its GPU and EGL fails to initialise, so SurfaceFlinger aborts and
# crash-loops:
#     D libEGL   : Failed to load drivers from property ro.hardware.egl
#     F SurfaceFlinger: couldn't find an OpenGL ES implementation
# which is exactly the failure this port already spent a day on.
#
# So decide at boot instead. This runs from 'on post-fs' -- after /vendor is
# mounted so the libraries exist, and well before zygote or SurfaceFlinger
# start, which is the point of no return: ro.* properties can only be set once,
# and the first GL client to load libEGL fixes the choice.
#
# iris became buildable in "mesa: Let iris configure without cross-building
# LLVM"; Mesa is now built as iris,virgl so one image serves both a VM and
# Intel metal. This script still earns its place -- AMD and NVIDIA have no
# driver here, and virtio-gpu and i915 want different gallium drivers out of
# the same image.

TAG=pc-select-egl

# This script runs from `exec_start` on early-init, and logd does not exist
# yet -- it starts several hundred ms later. Everything sent to `log -t` before
# that is discarded, which is why a boot that took every decision correctly
# still came back with zero pc-select-egl lines in logcat and no way to tell
# what it had chosen.
#
# /dev/kmsg is available from the moment init runs, and tools/collect-logs.sh
# already pulls the kernel log off the disk, so the decision lands somewhere
# that survives a power-off. <3> is KERN_ERR, which clears the loglevel=4 the
# default GRUB entry boots with; the logcat line is kept as well for the case
# where something starts this later, once logd is up.
say() {
    echo "<3>$TAG: $*" > /dev/kmsg 2>/dev/null || true
    log -t "$TAG" "$*" 2>/dev/null || true
}

# Detect by driver binding, not by the driver symlink on the DRM node.
#
# /sys/class/drm/card0/device/driver looked like the obvious source and is
# wrong: on virtio-gpu it resolves to "virtio-pci", the PCI transport, not to
# virtio_gpu. That silently selected the fallback and left the VM running
# SwiftShader while reporting success. The bus binding is unambiguous -- a
# device only appears under drivers/<name>/ when that driver has claimed it.
egl=mesa
why=""

if [ -n "$(ls /sys/bus/virtio/drivers/virtio_gpu/ 2>/dev/null | grep '^virtio')" ]; then
    # Mesa's virgl forwards GL to the host GPU.
    egl=mesa
    why="virtio_gpu"
else
    # Every KMS driver this Mesa can drive. One libgallium_dri.so carries
    # iris, radeonsi, nouveau and virgl, and the DRI loader picks between them
    # at runtime from the kernel driver name -- the same mechanism a Linux
    # distro uses, which is why one image covers all of them and there is no
    # per-vendor build.
    #
    # Order matters only on a hybrid machine. Intel and AMD integrated parts
    # are listed before nouveau because on a laptop with a discrete NVIDIA card
    # the integrated GPU is the one wired to the panel; the discrete card is
    # usually render-only and cannot scan out.
    for d in i915 xe amdgpu nouveau; do
        if [ -n "$(ls /sys/bus/pci/drivers/$d/ 2>/dev/null | grep '^0000:')" ]; then
            egl=mesa
            why="$d"
            break
        fi
    done
    # radeon is the pre-GCN driver. Mesa's r300/r600 are not built here, and
    # minigbm's backend_radeon is a dumb-buffer stub, so this is genuinely a
    # fallback rather than an oversight.
    if [ -z "$why" ]; then
        if [ -n "$(ls /sys/bus/pci/drivers/radeon/ 2>/dev/null | grep '^0000:')" ]; then
            egl=mesa
            why="radeon"
        fi
    fi
fi

# No DRM device recognised. This used to select ANGLE, on the reasoning that it
# needs no kernel driver at all -- but ANGLE is NOT INSTALLED. The only EGL
# implementation on these partitions is Mesa:
#
#     /vendor/lib64/egl/libEGL_mesa.so      /vendor/lib/egl/libEGL_mesa.so
#     /vendor/lib64/hw/vulkan.pastel.so     (SwiftShader Vulkan, not GL)
#
# so selecting "angle" pointed the loader at a library that does not exist, and
# zygote aborted on every start:
#
#     Abort message: 'couldn't find an OpenGL ES implementation, make sure one of
#     persist.graphics.egl, ro.hardware.egl and ro.board.platform is set'
#     #04 libEGL.so android::Loader::open   #08 ZygoteInit.preload
#
# That is a crash loop with no GUI whatsoever, once every 15 seconds, and it is
# what the AMD workstation did when amdgpu failed to bind. Mesa is the only
# answer that can ever succeed here, and it now carries softpipe, so it produces
# a context even when the only DRM device is simpledrm on the UEFI framebuffer.
# Slow, but a usable desktop rather than a boot loop.

[ -z "$why" ] && why="none"

# Report the finding; init.pc_x86_64.rc turns it into ro.hardware.egl.
#
# Setting ro.hardware.egl here is impossible, not merely denied:
#     neverallow { domain -init -vendor_init } exported_default_prop:property_service set;
# admits only init and vendor_init, and the same is true of
# persist.graphics.egl (gpuservice.te allows only init, vendor_init,
# gpuservice). Property sets in a vendor .rc run as vendor_init, so the one
# workable split is: this script detects, init.pc_x86_64.rc assigns.
#
# No waiting for the result: this runs as 'exec_start init_dev_config', which
# blocks init, so polling for ro.hardware.egl here would deadlock -- init
# cannot process the trigger until we exit. It fires immediately after, still
# far ahead of zygote.
# Which GPU actually drives the screen, for Mesa.
#
# On a two-GPU machine Mesa's EGL takes the first render node it can probe --
# droid_open_device() walks _eglGlobal.DeviceList in order -- with no idea which
# card owns the display. minigbm now allocates on the card with a connected
# connector (patch 0009), so on the AMD+NVIDIA workstation with HDMI on the
# 3070 Ti the buffers and the display were both nouveau while SurfaceFlinger
# still rendered on radeonsi:
#
#     gralloc: /dev/dri/card1 -> ACCEPTED, backend 'nouveau'
#     SurfaceFlinger: renderer : AMD Radeon Graphics (radeonsi, ...)
#     drmhwc : Failed to commit pset ret=-16 errno=16    [EBUSY]   x2448
#
# Cross-GPU either way is a blank screen. platform_android.c:1114 reads
# drm.gpu.vendor_name and, when set, uses ONLY a device matching it
# (droid_filter_device), so publishing the display GPU's driver name here makes
# Mesa, gralloc and drm_hwcomposer all land on the same card.
#
# Derived at runtime from the connectors, so it needs no per-board knowledge:
# whichever card has something plugged into it wins, on any machine.
# Two rules, in order, and no board knowledge in either:
#
#   1. A card only counts if something is actually plugged into it. A GPU with
#      no connected connector cannot be the display, whatever else it is.
#   2. Among the cards that DO drive a display, prefer the discrete one. On a
#      dual-GPU desktop the monitor may be in either socket, and the discrete
#      card is the faster of the two.
#
# Rule 1 is what keeps this honest on a hybrid laptop. There the NVIDIA part is
# a 3D controller with no connectors at all -- "Cannot find any crtc or sizes"
# -- and the panel is wired to the iGPU, so no amount of preference can make it
# the display. Rendering on it and scanning out on the iGPU is PRIME render
# offload, which is what the render-GPU block below does when it is asked to.
best_card= best_drv= best_rank=0
for c in /sys/class/drm/card[0-9]; do
    [ -e "$c" ] || continue

    connected=0
    for conn in "$c"-*; do
        [ -e "$conn/status" ] || continue
        if [ "$(cat "$conn/status" 2>/dev/null)" = "connected" ]; then
            connected=1
            break
        fi
    done
    [ "$connected" = 1 ] || continue

    drv=$(basename "$(readlink -f "$c/device/driver" 2>/dev/null)" 2>/dev/null)
    [ -n "$drv" ] && [ "$drv" != "driver" ] || continue

    # boot_vga is the firmware's own answer to "which one is the built-in
    # display adapter", so a card WITHOUT it is the add-in card. That is the
    # generic discrete test -- no vendor list, no PCI ids.
    if [ "$(cat "$c/device/boot_vga" 2>/dev/null)" = "1" ]; then
        rank=1          # integrated / boot VGA
    else
        rank=2          # discrete
    fi

    if [ "$rank" -gt "$best_rank" ]; then
        best_rank=$rank
        best_card=$c
        best_drv=$drv
    fi
done

if [ -n "$best_drv" ]; then
    say "display is on $(basename "$best_card") ($best_drv, $([ "$best_rank" = 2 ] && echo discrete || echo integrated))"
else
    say "no card has a connected connector"
fi

# ---------------------------------------------------------------- render GPU --
# Which card Mesa RENDERS on, which is not necessarily the one that scans out.
#
# drm.gpu.vendor_name is read by exactly one thing in this whole tree:
#
#     external/mesa3d/src/egl/drivers/dri2/platform_android.c
#         droid_open_device() -> property_get("drm.gpu.vendor_name")
#                             -> droid_filter_device() vs drmGetVersion()->name
#
# Grep for it: minigbm never reads it, and neither does drm_hwcomposer. An
# earlier comment here claimed it made "Mesa, gralloc and drm_hwcomposer all
# land on the same card", and that is simply not what the code does. Those two
# find their own device independently -- minigbm's init_try_nodes() prefers a
# card node that HAS a display, and drm_hwcomposer takes the card it can master.
#
# So this property selects the RENDER device and nothing else, and pointing it
# at a card that cannot scan out is not a bug. It is PRIME render offload:
#
#     gralloc  -> the display card    allocates scanout-capable buffers
#     Mesa     -> the offload card    renders into those buffers
#     drmhwc   -> the display card    scans them out
#
# The buffers are already shareable across vendors. minigbm is built with
# -DDRV_PC_FORCE_LINEAR (external/minigbm/Android.bp), so the Intel backend
# hands out DRM_FORMAT_MOD_LINEAR instead of the I915_FORMAT_MOD_4_TILED_MTL_RC_CCS
# it would otherwise prefer on Meteor Lake -- and a linear buffer is the one
# layout a non-Intel GPU can actually import.
#
# Discovery, generic and with no board knowledge, mirroring the rules above:
#
#   A card is an OFFLOAD candidate when it has a render node, drives no display,
#   AND is not the boot VGA device -- it can render, it cannot scan out, and it
#   is the add-in card. That is precisely what a muxless laptop's discrete GPU
#   is. A card that drives a display is never a candidate, because then there is
#   nothing to offload: it can render for itself, and rule 2 above already
#   preferred the discrete one.
#
# The boot_vga test is not decoration, and leaving it out is wrong in a way that
# is easy to miss. On a desktop with the monitor plugged into the DISCRETE card,
# the integrated GPU also has a render node and also has nothing connected --
# so "renders but drives no display" describes it perfectly, and offloading to
# it would render on the weaker part and scan out on the faster one, which is
# the exact inverse of the point. boot_vga is the firmware's own answer to
# "which one is built in", so requiring boot_vga != 1 keeps the offload target
# the add-in card on every machine, with no vendor list and no PCI ids.
#
# OFF BY DEFAULT, and gated on the kernel command line, because
# droid_open_device() does NOT fall back once a vendor name is set:
#
#     if (!droid_probe_device(disp, false)) { close(fd); fd = -1; }
#     break;                                  /* do not try any other device */
#
# If the offload card's Mesa driver cannot create a screen, EGL initialisation
# fails outright, SurfaceFlinger cannot find a GL implementation and aborts in a
# loop -- the exact failure this file's header exists to prevent. Making it a
# GRUB choice keeps the default boot on the path that is known to work and
# leaves a labelled way back at the menu.
offload_card= offload_drv=
if [ "$(getprop ro.boot.pc_render_gpu)" = "offload" ]; then
    for c in /sys/class/drm/card[0-9]; do
        [ -e "$c" ] || continue
        [ "$c" = "$best_card" ] && continue

        # Renders? A card only gets a render node when its driver offers one.
        ls "$c/device/drm/" 2>/dev/null | grep -q '^renderD' || continue

        # Add-in card? The built-in one is never the offload target.
        [ "$(cat "$c/device/boot_vga" 2>/dev/null)" = "1" ] && continue

        # Scans out? Any connected connector disqualifies it as an offload GPU.
        drives_display=0
        for conn in "$c"-*; do
            [ -e "$conn/status" ] || continue
            if [ "$(cat "$conn/status" 2>/dev/null)" = "connected" ]; then
                drives_display=1
                break
            fi
        done
        [ "$drives_display" = 0 ] || continue

        drv=$(basename "$(readlink -f "$c/device/driver" 2>/dev/null)" 2>/dev/null)
        [ -n "$drv" ] && [ "$drv" != "driver" ] || continue

        offload_card=$c
        offload_drv=$drv
        break
    done
fi

if [ -n "$offload_drv" ]; then
    setprop drm.gpu.vendor_name "$offload_drv"
    say "render offload: $(basename "$offload_card") ($offload_drv) renders, $(basename "${best_card:-none}") (${best_drv:-none}) scans out -> drm.gpu.vendor_name=$offload_drv"
elif [ -n "$best_drv" ]; then
    setprop drm.gpu.vendor_name "$best_drv"
    say "render on the display card $(basename "$best_card") -> drm.gpu.vendor_name=$best_drv"
else
    say "no card has a connected connector; leaving drm.gpu.vendor_name unset"
fi

setprop vendor.pc.gpu "$egl"

# Present-fence reliability, decided from the hardware rather than pinned.
#
# ro.vendor.hwc.drm.present_fence_not_reliable=true was a BUILD property, set
# unconditionally because virtio-gpu needs it (without it drm_hwcomposer returns
# BAD_DISPLAY from present and system_server's display thread aborts). Its own
# comment in device.mk said "Re-evaluate when running on real hardware." This is
# that re-evaluation.
#
# On metal it is actively harmful. drm_hwcomposer turns it into
# Capability::PRESENT_FENCE_IS_NOT_RELIABLE, SurfaceFlinger then clears
# Feature::kPresentFences, and SF can no longer measure when a frame actually
# reached the screen. Confirmed on the HP laptop:
#
#     dumpsys SurfaceFlinger -> Scheduler / Features / PresentFences=false
#
# with the visible result that every frame is booked as missed -- SuperTuxKart
# reported missedFrames == totalFrames (312 of 312) while averaging 21.3 ms
# against a 33 ms deadline, which cannot be true. Every performance number taken
# on this port was computed under that.
#
# i915, amdgpu and nouveau all produce real OUT_FENCE_PTR fences, so only the
# virtio case needs the workaround. The detection above is already exact: a
# device appears under /sys/bus/virtio/drivers/virtio_gpu/ only when that driver
# has claimed it. QEMU boots the same GRUB entries as bare metal, so this cannot
# be a kernel command line flag -- it has to be decided at runtime, here.
#
# This runs at early-init, long before the composer HAL starts, so the property
# is in place before anything reads it.
if [ "$why" = "virtio_gpu" ]; then
    setprop ro.vendor.hwc.drm.present_fence_not_reliable true
else
    setprop ro.vendor.hwc.drm.present_fence_not_reliable false
fi
say "present_fence_not_reliable=$(getprop ro.vendor.hwc.drm.present_fence_not_reliable)"

say "gpu=$why -> vendor.pc.gpu=$(getprop vendor.pc.gpu)"

