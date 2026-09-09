# Out-of-tree patches

Changes this port needs inside upstream projects. They are kept here as patch
files rather than as commits in a fork, because a fork means rebasing on every
uprev and leaves 1083 untouched AOSP projects looking touched.

None of these are upstreamable as they stand, so this directory is where they
live rather than a staging area on the way to a mailing list.

## Layout

**The directory a patch sits in is its destination.** Nothing reads the patch
to work out where it goes.

```
patches/
  linux/                              -> the kernel clone (linux/)
    0001-drm-virtio-....patch
  android/
    <repo manifest project path>/     -> android_17/<same path>
      0001-....patch
```

`<repo manifest project path>` is the project path exactly as the manifest
spells it, so:

| Patch file | Applies to |
|---|---|
| `patches/android/external/minigbm/0001-….patch` | `android_17/external/minigbm` |
| `patches/android/frameworks/native/0001-….patch` | `android_17/frameworks/native` |
| `patches/linux/0001-….patch` | `linux/` |

The kernel sits beside `android/` rather than under it because it is a plain
git clone, not a manifest project.

## Adding one

Commit in the project, then export with `git format-patch`:

```sh
cd android_17/external/minigbm
git format-patch -o ../../../patches/android/external/minigbm <base>..HEAD
```

Numbering is per directory and patches apply in sorted order, so keep the
`NNNN-` prefixes sequential when a later patch depends on an earlier one.

## Applying

```sh
./build.sh sync patches
```

This is re-runnable. It reverse-applies each patch first to see whether it is
already present and skips those, so it is safe to run against a tree that is
partly or fully patched. A patch that neither applies nor reverse-applies is a
hard error rather than a warning: it means the project is at a revision the
patch was not written against, which is exactly the case where silently
continuing would produce a subtly wrong build.

## What is here

| Patch | Why |
|---|---|
| `linux/0001-drm-virtio-accept-ABGR8888-and-XBGR8888-framebuffers` | virtio-gpu advertises only the ARGB orderings, so a guest composing into `RGBA_8888` (`DRM_FORMAT_ABGR8888`) cannot scan out at all |
| `android/external/minigbm/0001-…-pc-platform` | a linear-only `pc` gralloc platform for bare-metal x86, so buffers are not tiled for a GPU that is not doing the compositing |
| `android/external/minigbm/0002-…-virgl-context` | create the virgl context before allocating buffers; on a context-init host the kernel makes no virgl context otherwise |
| `android/external/minigbm/0003-…-amdgpu-dumb` | Nothing in `drv_backend_list` matches the `amdgpu` kernel driver name (`INIT_DUMB_DRIVER(radeon)` covers pre-GCN only), so gralloc exits at init on any Radeon. Adds a dumb-buffer backend, the same one NVIDIA gets. `-DDRV_AMDGPU` is *not* the fix: `dri.c` is in no build file, and `amdgpu.c` resolves `__driDriverGetExtensions_radeonsi`, which Mesa 26.1 does not export |
| `android/external/minigbm/0004-…-simpledrm-dumb` | simpledrm owns the UEFI framebuffer until a real GPU driver binds, and nothing matched the name `simpledrm`, so gralloc failed at init and SurfaceFlinger crash-looped instead of falling back to software rendering — 749 restarts in 62 minutes on the AMD workstation. A fallback, never a destination: once amdgpu or i915 binds, simpledrm is evicted and this backend is never consulted |
| `android/external/minigbm/0007-…-log-which-DRM-node` | `init_try_node()` discarded the one fact that matters when gralloc ends up with no backend: a failed `open()` was a silent `return NULL`, so a card node **refused** looked identical to one never reached. Each attempt now names the node, the kernel driver, and the decoded errno |
| `android/external/minigbm/0008-…-mapping-only` | `0005`'s CREATE_DUMB probe is the right test for a process that must **allocate** and the wrong one for a process that only **maps**. Every app links the mapper in-process; the render node is declined, the card node is correctly refused (`private/app.te:606` neverallows it), and the mapper ends up with no driver — so HWUI aborts. Falls back to a render node with the probe suppressed |
| `android/hardware/interfaces/0001-audio-don-t-discard-…` | the AIDL audio HAL overwrites the built-in mic's configured address, which is what selects the ALSA capture device; on a PC that pins capture to the analog jack instead of the internal DMIC array |

Everything else this port needs lives in `android_17/device/pcx86/pc_x86_64/`,
which is a new device directory rather than a change to an existing project.
That is why this list is nine entries long: the kernel is otherwise stock
mainline and AOSP is otherwise stock `android17-release`.
