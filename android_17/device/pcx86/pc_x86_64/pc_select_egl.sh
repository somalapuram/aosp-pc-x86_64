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
egl=angle
why=""

if [ -n "$(ls /sys/bus/virtio/drivers/virtio_gpu/ 2>/dev/null | grep '^virtio')" ]; then
    # Mesa's virgl forwards GL to the host GPU.
    egl=mesa
    why="virtio_gpu"
else
    # Intel first: iris is in this Mesa, so these get real acceleration.
    for d in i915 xe; do
        if [ -n "$(ls /sys/bus/pci/drivers/$d/ 2>/dev/null | grep '^0000:')" ]; then
            egl=mesa
            why="$d"
            break
        fi
    done
    # Anything else real falls back. radeonsi needs LLVM and nouveau has no
    # minigbm backend, so this Mesa has nothing for them; ANGLE over SwiftShader
    # is slow but correct, and it is what got this port to Launcher on Meteor
    # Lake.
    if [ -z "$why" ]; then
        for d in amdgpu radeon nouveau; do
            if [ -n "$(ls /sys/bus/pci/drivers/$d/ 2>/dev/null | grep '^0000:')" ]; then
                egl=angle
                why="$d"
                break
            fi
        done
    fi
fi

# No DRM device recognised: ANGLE needs no kernel driver at all, so a slow UI
# beats a boot loop.
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
setprop vendor.pc.gpu "$egl"

log -t "$TAG" "gpu=$why -> vendor.pc.gpu=$(getprop vendor.pc.gpu)"

