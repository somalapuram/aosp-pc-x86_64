# AOSP 17 on bare-metal x86_64

Android 17 booting on an ordinary PC — real hardware, not an emulator and not
Cuttlefish — against a **mainline** Linux kernel rather than an Android Common
Kernel, with Intel and AMD graphics as the target.

Boots to Launcher on Intel Meteor Lake.

## Status

| Area | State |
|---|---|
| Boot to Launcher | ✅ on Intel Meteor Lake (device ID `7dd5`) |
| Kernel | ✅ mainline 7.2 + one 12-line virtio-gpu patch (`patches/linux/`); everything else is a config fragment |
| Display / KMS | ✅ real scanout via drm_hwcomposer, eDP-1 at 60 Hz |
| GPU firmware | ✅ GuC / DMC / HuC / GSC linked into the image |
| gralloc | ✅ Intel (i915 + xe) — ❌ AMD, blocked on Mesa |
| Rendering | ⚠️ **software only** (SwiftShader + ANGLE). Slow. See below. |
| QEMU display | ✅ boot animation and UI render (needs `DISPLAY_MODE=gtk` or `-vnc`) |
| Audio | ✅ AIDL HAL from the `com.android.hardware.audio` APEX |
| SELinux | ⚠️ permissive |
| adb over TCP | ❌ refused, though `adbd` is listening |
| Verified boot | ❌ AVB disabled; static partitions, no dynamic partitions |

The largest remaining piece of work is **Mesa**. Nothing renders on the GPU
yet: everything goes through SwiftShader on the CPU, which is why the UI is
sluggish. Building `iris`/`anv` is what unlocks real performance, lets the
`DRV_PC_FORCE_LINEAR` workaround be dropped, and is a prerequisite for AMD
gralloc — `amdgpu.c` needs the Mesa DRI loader. See `doc/05-graphics.md` §4.

AMD is supported *kernel-side* (amdgpu with Display Core is built in) but not
in gralloc, so an AMD machine will not get a working display stack yet.

## Layout

```
build.sh                     one entry point for the whole loop
config/pc_x86_64.fragment    kernel config delta over x86_64_defconfig
firmware/i915/               Intel GPU firmware, linked into the kernel
manifests/                   the AOSP tree, pinned to exact revisions
patches/                     out-of-tree patches: minigbm (2), kernel virtio-gpu (1)
tools/                       source sync, disk assembly, QEMU, USB writer, logs
doc/                         how it was derived, and why each piece is there
android_17/device/pcx86/     the device target (lives at an AOSP path, but is
                             this project's own code)
```

`android_17/` and `linux/` are **not** committed — together they are ~350 GB of
unmodified upstream code. They are reproduced from pinned revisions instead.

## Upstream pins

| Tree | Source | Revision |
|---|---|---|
| AOSP | `https://android.googlesource.com/platform/manifest` | `android17-release`, pinned per-project in `manifests/aosp-android17-pinned.xml` (1084 projects, each locked to a SHA) |
| Kernel | `git@github.com:torvalds/linux.git` (or the canonical `https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git`) | `0d8395707651` (`v7.2-rc6-59-g0d8395707651`) |

The kernel carries **one** local patch, in `patches/linux/`: `drm/virtio`
advertised only `XRGB8888`, so Android — which composes into `ABGR8888` — could
never scan out in a VM. It is 12 lines, upstreamable, and affects the VM only;
real hardware never needed it. Everything else about the kernel is a config
symbol, so there is still no fork, just one patch applied by `./build.sh sync`.

## Getting the sources

Clone this repo, then let `./build.sh sync` populate the two upstream trees
*inside* it. The clone already contains `android_17/device/pcx86/`; `repo`
leaves it alone, because it is not one of the manifest's projects.

```sh
git clone https://github.com/somalapuram/aosp-pc-x86_64.git
cd aosp-pc-x86_64
./build.sh sync
```

That does three things: `repo init`/`sync` of AOSP at the pinned revisions, a
clone of the kernel at `0d8395707651`, and `git am` of the one out-of-tree
patch. It is safe to interrupt and re-run — each step checks for its own
completion first — and it can be narrowed to `sync aosp`, `sync kernel` or
`sync patches`.

Budget several hours and around 400 GB for the first run: AOSP source is ~200 GB
and a build needs roughly that again on top.

```sh
JOBS=16 ./build.sh sync                    # sync parallelism (default 32)
REFERENCE=/path/to/other/checkout ./build.sh sync
PINNED=0 ./build.sh sync                   # follow android17-release
KERNEL_REMOTE=<url> ./build.sh sync kernel
```

`JOBS` is network parallelism, not a core count — 32 by default. Going as high
as `nproc` on a many-core host oversubscribes the link and googlesource starts
refusing connections.

### If the transfer is slow

It may well be, and not because of your bandwidth. On the machine this was
developed on, the same link that pulled **16 MB/s** from a general CDN got
**~35 KB/s** from `android.googlesource.com` and **under 500 KB/s** from both
`git.kernel.org` and GitHub — with the kernel clone dropping outright after
156 MB:

```
fetch-pack: unexpected disconnect while reading sideband packet
fatal: early EOF
```

That matters more than it sounds, because **a failed `git clone` deletes its own
partial output** — an interrupted transfer costs everything downloaded so far.
The kernel defaults to `git@github.com:torvalds/linux.git`; `git.kernel.org` is
the canonical source and works equally well. Neither is reliably faster than the
other, so measure rather than switch on faith.

If you already have a checkout of either tree, borrow from it instead:

```sh
REFERENCE=/path/to/other/checkout ./build.sh sync
```

That expects a directory containing `android_17/` and/or `linux/`, and passes
`--reference --dissociate` to `repo init` and `git clone`. Objects are read from
local disk and then *copied*, so the result stands alone and the reference can
be deleted afterwards. Minutes instead of days.

`PINNED=0` tracks `android17-release` as it moves rather than reproducing the
exact tree this port was built against. Expect to fix things if you do.

### If the build fails with undefined Soong modules

An interrupted sync can leave a project with a fully populated `.git` and an
*empty working tree* — the fetch phase completed, the checkout phase never ran.
Nothing reports it:

- `repo sync` prints "repo sync has finished successfully"
- `repo sync -l` also succeeds and changes nothing, because HEAD already matches
  the manifest, so repo considers the project done
- the directory exists, so any `[ -d ]` check passes

The only tell is `git status` listing every tracked file as deleted. It surfaces
much later, and far from the cause, as a wall of Soong errors naming modules
that live in whichever project was hit. With `bionic` empty:

```
error: external/zlib/Android.bp:100:1: "libz_defaults" depends on undefined module "bug_24465209_workaround"
error: external/python/cpython3/Android.bp:97:1: "py3-interp-defaults" depends on undefined module "no_bti"
```

Nothing there mentions a bad checkout. `./build.sh sync` now checks for this and
repairs it automatically, and it can be run on its own at any time:

```sh
./build.sh sync verify
```

It distinguishes a broken checkout from a project that is legitimately empty
upstream — AOSP carries several placeholder repos with no tracked files, and
those are reported, not "fixed".

## Building

```sh
./build.sh deps      # host prerequisites
./build.sh kernel    # mainline kernel + config fragment
./build.sh android   # AOSP for pc_x86_64
./build.sh image     # assemble a GPT disk image
./build.sh run       # boot it in QEMU
./build.sh test      # assert 11 properties of a healthy boot
./build.sh usb /dev/sdX   # write to a USB disk for real hardware
./build.sh logs      # pull kmsg + logcat back off that disk
```

`./build.sh all` does kernel + android + image.

### Viewing the UI over SSH

X11 forwarding cannot carry `gtk,gl=on` -- there is no direct rendering over
the wire, so QEMU reports `DRI3 error: Could not get DRI3 device` and you get
nothing accelerated. Use VNC, which renders locally and ships finished frames:

```sh
DISPLAY_MODE=vnc ./build.sh run
```

It prints the exact tunnel command. The server binds to **127.0.0.1 only** and
has no password, so reach it through your existing SSH session rather than
exposing it:

```sh
ssh -L 5901:127.0.0.1:5901 user@host      # then VNC to localhost:5901
```

MobaXterm has a VNC client built in (Sessions -> VNC, host `localhost`, port
`5901`).

Do not judge the display by `./build.sh test`'s screendump warning: QMP
`screendump` cannot read a GL scanout and reports a black frame regardless of
what is really on screen. See `doc/05-graphics.md` 5.2.

## On real hardware

Disable Secure Boot — the GRUB build here is unsigned. The image installs to
the removable media path (`/EFI/BOOT/BOOTX64.EFI`), so firmware finds it without
an NVRAM entry. Prefer an Intel machine; AMD will boot but has no gralloc, and
NVIDIA has no Android driver at all.

There is no serial console on most PCs and no virtio-console, so a failed boot
would normally leave nothing to read. The image persists both the kernel log and
logcat to `/data`; `./build.sh logs` mounts userdata read-only afterwards and
pulls them out.

## Debugging notes

Most of the difficulty in this port was not writing code — it was that the
platform fails in places far from the cause. A few worth knowing:

- A missing gralloc backend presents as **SurfaceFlinger hanging**, with no
  crash, no watchdog kill and no DRM error, two services away from the fault.
- A missing `xi:include` in the audio policy presents as a **watchdog killing
  system_server**, with nothing mentioning audio.
- A missing cgroup controller presents as **`ueventd` failing to start**.
- Building the wrong lunch target does not fail; it succeeds, and silently
  leaves `out/target/product/pc_x86_64` untouched.

`doc/` records the evidence for each of these rather than just the conclusion.

## Licence

Apache 2.0 — see `LICENSE`.

`firmware/i915/` contains Intel GPU firmware redistributed from
[linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git)
under the terms in `firmware/LICENSE.i915`, which permits redistribution in
binary form provided that licence accompanies it.

`patches/` contains a change to `external/minigbm`, which is BSD-3-Clause and
remains so.
