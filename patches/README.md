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
| `android/hardware/interfaces/0001-audio-don-t-discard-…` | the AIDL audio HAL overwrites the built-in mic's configured address, which is what selects the ALSA capture device; on a PC that pins capture to the analog jack instead of the internal DMIC array |

Everything else this port needs lives in `android_17/device/pcx86/pc_x86_64/`,
which is a new device directory rather than a change to an existing project.
That is why this list is four entries long: the kernel is otherwise stock
mainline and AOSP is otherwise stock `android17-release`.
