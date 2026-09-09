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
#   amdgpu / radeon /  -> angle  This Mesa carries iris and virgl only.
#   nouveau                      radeonsi needs LLVM and nouveau has no minigbm
#                                backend, so neither has a driver here.
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
for c in /sys/class/drm/card[0-9]; do
    [ -e "$c" ] || continue
    for conn in "$c"-*; do
        [ -e "$conn/status" ] || continue
        if [ "$(cat "$conn/status" 2>/dev/null)" = "connected" ]; then
            drv=$(basename "$(readlink -f "$c/device/driver" 2>/dev/null)" 2>/dev/null)
            if [ -n "$drv" ] && [ "$drv" != "driver" ]; then
                setprop drm.gpu.vendor_name "$drv"
                log -t "$TAG" "display is on $(basename "$c") ($drv) -> drm.gpu.vendor_name=$drv"
            fi
            break 2
        fi
    done
done

setprop vendor.pc.gpu "$egl"

log -t "$TAG" "gpu=$why -> vendor.pc.gpu=$(getprop vendor.pc.gpu)"

