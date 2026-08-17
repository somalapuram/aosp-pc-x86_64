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
#   i915 / amdgpu      -> angle  Mesa here is built with virgl ONLY. iris
#                                cannot be built yet: meson.build puts
#                                with_gallium_iris in with_driver_using_cl
#                                unconditionally, CLC hard-requires LLVM, and
#                                there is no LLVM cross-built for Android in
#                                this tree (doc/05-graphics.md 4.2 calls that
#                                "the sharpest edge in the whole approach").
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
# Delete this and set ro.hardware.egl=mesa directly once iris is buildable.

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
    for d in i915 xe amdgpu radeon nouveau; do
        if [ -n "$(ls /sys/bus/pci/drivers/$d/ 2>/dev/null | grep '^0000:')" ]; then
            # Mesa here has no driver for real GPUs yet -- iris needs LLVM,
            # which is not cross-built for Android in this tree. ANGLE over
            # SwiftShader is slow but correct, and it is what got this port to
            # Launcher on Meteor Lake.
            egl=angle
            why="$d"
            break
        fi
    done
fi

# No DRM device recognised: ANGLE needs no kernel driver at all, so a slow UI
# beats a boot loop.
[ -z "$why" ] && why="none"

setprop ro.hardware.egl "$egl"

log -t "$TAG" "gpu=$why -> ro.hardware.egl=$(getprop ro.hardware.egl)"
