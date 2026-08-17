# 05 — Graphics: Intel iGPU + AMD GPU

**This is the hard part of the project.** Read [01-scope-and-findings.md](01-scope-and-findings.md) §3
first for the evidence behind the claims here.

---

## 1. The target stack

```
        SurfaceFlinger  /  apps
                 │
    ┌────────────┴─────────────┐
    │                          │
 gralloc (AIDL)          EGL / GLES / Vulkan
 minigbm                 Mesa: iris | radeonsi
 -DDRV_I915                    ANV   | RADV
 -DDRV_XE                         │
 -DDRV_AMDGPU                     │
    │                             │
    └────────────┬────────────────┘
                 │
        drm_hwcomposer (HWC3 AIDL)
                 │
            /dev/dri/card0
                 │
      kernel: i915 | xe | amdgpu
```

Three of these four layers are ready or nearly ready. **Mesa is not.**

| Layer | State | Work |
|---|---|---|
| kernel DRM | config only | [03-kernel.md](03-kernel.md) §3 |
| drm_hwcomposer | ✅ ready | none |
| minigbm | Intel ✅ (needs `platform=intel`, §3.0) / AMD ❌ | §3 below — small |
| Mesa | ❌ not built at all | §4 below — **large** |

---

## 2. One image, both vendors

minigbm selects its backend **at runtime** by DRM driver name.
`external/minigbm/drv.c:101`:

```c
drm_version = drmGetVersion(fd);
...
    if (!strcmp(drm_version->name, b->name)) {
```

So a single `libminigbm_gralloc_*` with `DRV_I915`, `DRV_XE` and `DRV_AMDGPU`
all compiled in serves Intel and AMD from one build. That is exactly what a
generic PC image wants.

Mesa works the same way — the DRI loader picks `iris`, `crocus` or `radeonsi`
based on the PCI ID, provided all are built into the shipped library.

**Design decision: build one universal image.** Do not fork per-vendor.

---

## 3. minigbm — adding AMD

### 3.0 First, do not ship platform `generic`

Before any of the AMD work below, make sure the product actually selects a
platform that compiles GPU backends in. `generic` defines **no** `DRV_*` at
all:

```blueprint
generic_cflags = ["-DHAS_DMABUF_SYSTEM_HEAP"]
```

This is a trap, because `drv.c` registers `backend_virtgpu` *unconditionally*,
outside any `#ifdef`. So `generic` allocates fine against QEMU's virtio-gpu and
the entire VM bring-up passes — then fails on every real GPU. On Meteor Lake:

```
E ...allocator-service.minigbm: Failed to initialize Minigbm AIDL allocator.
avc: denied { ioctl } path="/dev/dri/card0" ioctlcmd=0x6400   (DRM_IOCTL_VERSION)
     scontext=hal_graphics_allocator_default tcontext=graphics_device
```

minigbm asks the kernel for the driver name, gets `i915`, finds no matching
entry in its backend table and exits. init restarts it every five seconds
forever, and **nothing ever logs the actual reason**.

The symptom looks nothing like gralloc. SurfaceFlinger reaches

```
I SurfaceFlinger: SurfaceFlinger's main thread ready to run. Initializing graphics H/W...
D SurfaceFlinger: Threaded RenderEngine with SkiaGL Backend (Ganesh)
```

and then goes silent for the rest of the boot. It never publishes
`SurfaceFlingerAIDL`, so every other process blocks behind
`Waited one second for SurfaceFlingerAIDL`, and the boot stalls with **zero
crashes, zero watchdog kills and zero DRM errors** — the kernel side is
perfectly healthy, i915 bound, firmware loaded, `/dev/dri/card0` present.
Debugging starts at SurfaceFlinger and the cause is two services away.

Use `intel`, which is already upstream and needs no patch:

```makefile
$(call soong_config_set,minigbm,platform,intel)
```

`i915.c` and `xe.c` are self-contained — they include only `xf86drm.h` — so
this covers i915 (through Meteor Lake) and Xe (Lunar Lake and newer) at the
cost of a flag. `backend_virtgpu` stays compiled in, so the QEMU loop is
unaffected. AMD is the part that genuinely needs work; that is the rest of §3.

### 3.1 The gap

`external/minigbm/Android.bp` defines platforms `generic`, `intel`, `meson`,
`msm`, `mt8186`, `mt8188`, `mt8196`. Intel maps to:

```blueprint
intel_cflags = [
    "-DDRV_I915",
    "-DDRV_XE",
]
```

`amdgpu.c` and `backend_amdgpu` exist and are guarded by `#ifdef DRV_AMDGPU`,
but **nothing in Soong ever defines it** — only the ChromeOS `Makefile` does.

### 3.2 The `pc` platform

**Status: implemented, Intel only.** The AMD half below is still to do.

There is a second reason for a custom platform beyond AMD, and it bites first.
Stock `intel` boots far enough to light the panel — eDP-1 connects at 60 Hz,
drm_hwcomposer sets power mode 2 — and then kills SurfaceFlinger 41 times over:

```
E surfaceflinger: Mapping failed.
W Gralloc5: lock(0x…, …) failed: 3            ← BAD_VALUE
E surfaceflinger: Buffer was not locked.
E skia   : ** ERROR ** Could not create EGL image, err = (0x300c)   ← EGL_BAD_PARAMETER
F SurfaceFlinger: Failed to create a valid texture. […]:[384,384] isWriteable:1 format:1
```

`i915_add_combinations()` adds linear combinations at priority 1 and then
overrides them with X-tiled (2) and Y/4-tiled (3) for every usage that carries
no explicit `BO_USE_SW_*` or `BO_USE_LINEAR` flag — which is precisely how
SurfaceFlinger allocates a GPU texture. And `i915_bo_map()` only takes the mmap
path when `tiling == I915_TILING_NONE`:

```c
if (bo->meta.tiling == I915_TILING_NONE) {
        if (i915->has_mmap_offset) {
```

So a tiled buffer cannot be locked for CPU access at all. Under Mesa that is
correct and desirable. Under SwiftShader — which reads and writes every pixel
with the CPU — it is fatal, and the renderer really is software:

```
ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (LLVM 16.0.0)), SwiftShader driver-5.0.0)
```

Hence `pc` = `intel` + a linear-only allocation policy:

```blueprint
pc_cflags = intel_cflags + [
    "-DHAS_DMABUF_SYSTEM_HEAP",
    "-DDRV_PC_FORCE_LINEAR",
]
```

```blueprint
] + select(soong_config_variable("minigbm", "platform"), {
    "generic": generic_cflags,
    "intel":   intel_cflags,
    "meson":   meson_cflags,
    "pc":      pc_cflags,          // <-- bare-metal x86, linear-only
    "msm":     msm_cflags,
    ...
```

`DRV_PC_FORCE_LINEAR` does two things in each of `i915.c` and `xe.c`: it points
`*_get_modifier_order()` at a one-entry `DRM_FORMAT_MOD_LINEAR` array, and it
returns early from `*_add_combinations()` before any tiled combination is
registered. Both paths matter — the first covers `create_with_modifiers`, the
second the plain create path.

Linear costs real performance, but nothing is rendering on the GPU yet, so
there is none to lose. **Drop the flag (revert the product to `intel`) as soon
as Mesa is shipping** — §4 — since by then tiling is pure gain and the CPU is
no longer touching these buffers.

**No new library module is required**, and adding one would be a mistake. An
earlier draft of this document proposed a `libminigbm_gralloc_pc` /
`gralloc.minigbm_pc` pair mirroring the `_intel` block. That is dead weight
here: the AIDL allocator service and `mapper.minigbm` both hard-code
`libminigbm_gralloc`, so a parallel library would be built and never loaded.

```blueprint
cc_binary {
    name: "android.hardware.graphics.allocator-service.minigbm",
    defaults: ["minigbm_cros_gralloc_defaults"],
    shared_libs: [ …, "libminigbm_gralloc", … ],
```

The `soong_config_variable` select sits in `minigbm_defaults`, which every one
of those modules inherits, so setting the product's platform reaches all of
them at once. The existing `libminigbm_gralloc_*` variants only exist for the
legacy gralloc0 HAL.

One wrinkle worth knowing: `libminigbm_gralloc` also sets `cflags:
generic_cflags` on itself. Soong *appends* those to whatever the defaults
contribute rather than replacing them, so the library ends up with both — which
is why `pc_cflags` repeats `-DHAS_DMABUF_SYSTEM_HEAP` rather than relying on it,
and why switching platforms does not silently drop the dma-buf heap path.

For the AMD half, add `-DDRV_AMDGPU` to `pc_cflags` and `libdrm_amdgpu` to the
shared libs of `libminigbm_gralloc`. `libdrm_amdgpu` is already a buildable
Soong module (`external/libdrm/amdgpu/Android.bp`).

> `amdgpu.c` includes `<amdgpu.h>` and `<amdgpu_drm.h>` and pulls in minigbm's
> `dri.c`, which dlopens a Mesa gallium driver. AMD gralloc therefore depends on
> §4 landing first — it is not a flag flip, unlike the Intel side.

### 3.3 Device wiring

In `device/pcx86/pc_x86_64/device.mk`, following the idiom used by
`device/linaro/dragonboard/shared/graphics/minigbm_msm/device.mk:18`:

```make
$(call soong_config_set,minigbm,platform,pc)

PRODUCT_PACKAGES += \
    android.hardware.graphics.allocator-service.minigbm \
    mapper.minigbm
```

### 3.4 Upstreaming

Split this in two before sending anything.

The AMD half — a platform that compiles `DRV_AMDGPU` alongside the Intel
backends — is small, generally useful and belongs upstream; sending it reduces
the long-term rebase burden.

`DRV_PC_FORCE_LINEAR` does **not** belong upstream. It is a bring-up crutch that
trades correctness-under-SwiftShader for performance, and it should be deleted
from this tree rather than upstreamed once §4 lands. Keeping it local also keeps
the reminder visible.

---

## 4. Mesa — the critical path

### 4.1 The problem restated

`external/mesa3d/Android.bp` is 701 lines and builds **only** gfxstream /
virtio guest modules. Zero native GPU drivers. The full upstream source is
present — `src/gallium/drivers/{iris,crocus,radeonsi,llvmpipe,zink}`,
`src/intel` (ANV), `src/amd` (RADV) — but Soong never compiles any of it.

AOSP 17's Mesa integration exists purely to serve virtualized guests.

### 4.2 Option A — regenerate `Android.bp` via meson2hermetic

The documented path. From `external/mesa3d/README.aosp.md`:

```sh
git clone -b meson2hermetic https://github.com/gurchetansingh/mesonbuild.git
cd external/mesa3d
python3 ~/meson/meson.py convert android aosp_mesa3d
```

You would regenerate with the driver set you want, roughly:

```
-Dgallium-drivers=iris,crocus,radeonsi,llvmpipe,zink
-Dvulkan-drivers=intel,amd
-Dplatforms=android
-Dandroid-libbacktrace=disabled
```

**Pros:** stays inside the AOSP build; hermetic; matches Google's intent.

**Cons:**
- Depends on a **third-party fork of meson** that is not in your tree
- The `aosp_mesa3d` preset is not in the tree either — it ships with that fork
- Unknown whether the converter handles the full native driver set; it was
  plainly exercised for the gfxstream subset only
- LLVM dependency: `radeonsi` and `llvmpipe` need LLVM. AOSP's prebuilt LLVM
  is not packaged as a Mesa-consumable library. **This is the sharpest edge
  in the whole approach.**

**Verdict:** try this first, timebox it hard (a week). If the converter
chokes on `radeonsi`/LLVM, switch to Option B without sunk-cost hesitation.

### 4.3 Option B — out-of-tree meson build, import as prebuilts

Build Mesa the way every other Android GPU vendor does: separately, with the
NDK, then drop the `.so` files into `vendor/`.

```
mesa (meson + NDK cross-file)  →  libgallium_dri.so
                                  libEGL_mesa.so
                                  libvulkan_intel.so
                                  libvulkan_radeon.so
                                       │
                                       ▼
                          vendor/pcx86/proprietary/lib64/
                                       │
                                       ▼
                          prebuilt_* modules in Android.bp
```

Cross-file sketch (`android-x86_64.cross`):

```ini
[binaries]
c = 'x86_64-linux-android34-clang'
cpp = 'x86_64-linux-android34-clang++'
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
```

**Pros:**
- Decoupled from AOSP's build entirely — iterate on Mesa independently
- You control LLVM: build or vendor your own, no AOSP LLVM fight
- Well-trodden — this is how Android-x86 and the various Mesa-on-Android
  efforts have always done it
- Upstream Mesa has genuine Android support (`-Dplatforms=android`), actively
  maintained for ARM SoCs; the x86 drivers are the same codebase

**Cons:**
- Prebuilt blobs in your tree — worse hygiene, manual refresh
- You own the NDK/AOSP ABI-compatibility question
- Vendor/system ABI boundaries need care (`LOCAL_PROPRIETARY_MODULE`)

**Verdict:** the pragmatic path, and where I expect you to end up.

### 4.4 Recommendation

Timebox Option A to one week. Default to Option B. Either way, **do not put
Mesa on the critical path for first boot** — use SwiftShader (§5).

### 4.5 Driver selection per vendor

| Hardware | Gallium (GL) | Vulkan |
|---|---|---|
| Intel Gen8–Gen12 (Broadwell → Alder Lake) | `iris` | ANV (`intel`) |
| Intel Gen4–Gen7 (older) | `crocus` | — |
| Intel Xe / Arc / Lunar Lake+ | `iris` (via `xe` kernel driver) | ANV |
| AMD GCN / RDNA | `radeonsi` | RADV (`amd`) |
| Software fallback | `llvmpipe` | SwiftShader |

Build them all in. Runtime PCI-ID matching handles selection.

⚠️ `radeonsi` and `llvmpipe` both require LLVM. `iris` does not. **If LLVM
becomes a blocker, Intel-only is achievable much sooner than AMD.** Consider
shipping Intel first and adding AMD in a second pass — the minigbm patch in
§3 is vendor-neutral and can land either way.

---

## 5. SwiftShader — the bring-up unblock

`external/swiftshader/` is present with a working `Android.bp`. It is a pure
software Vulkan/GLES implementation needing no GPU driver at all.

Cuttlefish's usage, from `device/google/cuttlefish/shared/swiftshader/`:

```make
BOARD_VENDOR_SEPOLICY_DIRS += device/google/cuttlefish/shared/swiftshader/sepolicy
PRODUCT_REQUIRES_INSECURE_EXECMEM_FOR_SWIFTSHADER := true
```

Note `INSECURE_EXECMEM` — SwiftShader JITs, so it needs writable-executable
memory and a matching SELinux exception. Copy Cuttlefish's sepolicy directory.

**Use SwiftShader to reach a booting Android UI on bare metal before Mesa
works at all.** This is what keeps a 1–3 month Mesa effort off your critical
path, and it means you debug the HAL long tail against a working display
instead of blocked behind a GPU driver.

---

### 5.1 Making the QEMU display work

The VM renders the boot animation and UI. Getting there took three fixes, all
carried in `patches/`, and each one hid the next.

**1. virtio-gpu would not accept Android's format.** `drm/virtio` advertised a
single plane format and rejected everything else:

```c
if (mode_cmd->pixel_format != DRM_FORMAT_HOST_XRGB8888 &&
    mode_cmd->pixel_format != DRM_FORMAT_HOST_ARGB8888)
        return ERR_PTR(-ENOENT);
```

SurfaceFlinger composes into `RGBA_8888` → `DRM_FORMAT_ABGR8888`, so every
`ADDFB2` failed. The transport could always carry it —
`VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM` is in the uapi header and QEMU maps it — the
driver simply never offered it. Note virtio names formats by memory byte order
and DRM by little-endian word, so `ABGR8888 → R8G8B8A8_UNORM` looks reversed
and is correct; swapping them compiles and shows as red/blue exchanged.

**2. Pixels never reached the host.** With framebuffers finally being created,
the screen was still black, and the host was logging:

```
vrend_renderer_transfer_iov: context error reported 6 "BootAnimation" Illegal resource 9
```

On a context-init host the kernel does not create a virgl context in
`gem_object_open()`, so `context_created` is false and **no buffer is ever
attached**. The context is created later by the first transfer ioctl, after
every buffer already missed its attach. minigbm's `cross_domain` backend calls
`CONTEXT_INIT`; its `virgl` backend never did. Nothing fails in the guest —
allocation, commits and presents all succeed and the host receives nothing.

**3. Buffers had to be linear**, since the renderer is SwiftShader on the CPU
(§3.2).

### 5.2 The screendump trap

`ENOENT` for a refused format cost a lot of time — it reads as a missing GEM
handle, so the search starts at buffer imports rather than the format list. But
the worse trap was the measuring instrument:

**QMP `screendump` cannot read a GL scanout.** It samples QEMU's
`DisplaySurface`, which is not updated for a dmabuf/GL scanout, so it returns an
all-black frame no matter what is genuinely on screen. Worse, the *cursor* plane
takes the non-GL path and does appear — so the capture looks plausible and is
wrong: a black screen with a lone cursor, which is also exactly what a real
scanout failure looks like.

This produced a false negative that survived several correct fixes and led to
the conclusion that the display still did not work when it did. To actually
look at the guest:

```sh
./build.sh run                      # over SSH: picks VNC on 127.0.0.1:5901
DISPLAY_MODE=gtk ./build.sh run     # force a GTK window on a local display
```

Over an SSH session with X11 forwarding, plain `./build.sh run` resolves to VNC
by itself and prints the tunnel command, because `gtk,gl=on` onto a forwarded
display floods stdout with `GDK_IS_MONITOR` assertions and corrupts the serial
console (§5.4). Verified end-to-end with an RFB client: a full 2560x1600 frame
of the launcher, wallpaper and all.

`./build.sh test` captures the UI from *inside* the guest with `screencap`
(written base64 over a virtio-console port), which is independent of scanout and
works headlessly. That is the check to trust.

### 5.3 Blob resources segfault QEMU 10.2.1

`blob=on` lets the guest and host share buffers instead of copying every frame
through the virtqueue, so it looks like the obvious win at 2560x1600. It is off
by default anyway, for two reasons: it made no measurable difference — Mesa's
virgl already keeps the heavy buffers host-side — and it crashes the host.

Three crashes, all byte-identical, and all in the same place:

```
qemu-system-x86[189101]: segfault at 0 ip ... error 4 in libc.so.6[1aa362]

#0  __strcmp_evex          rsi = 0x0
#1  cpr_delete_fd ()
#2  qemu_ram_free ()       <- a virtio-gpu worker thread, not the main loop
```

`error 4` is a userspace *read* of address 0, and the faulting instruction is
the second load of `strcmp` — so this is `strcmp(valid, NULL)`, a plain missing
NULL check rather than memory corruption. `qemu_ram_free()` does:

```
mov  0x10(%r12),%rdi      ; block->mr
call <memory_region_name>
mov  %rax,%rdi            ; name -- NULL here
call <cpr_delete_fd>      ; -> strcmp(elem->name, NULL)
```

The block being freed is a 1 MiB `RAMBlock` with an empty `idstr` — a
host-visible blob resource — and its `MemoryRegion` has a NULL QOM parent
(`Object::parent` at `mr+0x20` reads 0). `memory_region_name()` falls back to
`object_get_canonical_path_component()`, which returns NULL for an unparented
object. So the name is NULL and `cpr_delete_fd()` walks its list comparing
against it. That is a QEMU bug, not a misconfiguration.

It needs *both* halves of what `blob=on` turns on, which is why it appeared only
once Mesa started driving virgl for real:

- `blob=on` — so blob resources are allocated and freed at all. SwiftShader
  never created one, which is why this was invisible for the whole bring-up.
- `-object memory-backend-memfd` — so `cpr_state.fds` is non-empty. The first
  thing `cpr_delete_fd()` does is `test %rbx,%rbx; je <ret>` on the list head,
  so with an empty list the NULL name is never dereferenced.

Set `BLOB=on` to opt back in once the host QEMU carries a fix.

Worth repeating the method, because guessing was losing: the crash would not
reproduce under load, and what settled it was the core dump apport had already
written to `/var/crash` — `apport-unpack` plus `libvirglrenderer1-dbgsym` gave
the backtrace directly. Ubuntu ships no `qemu-system-x86-dbgsym` matching the
`-updates` point release, but the frames that mattered were exported symbols.

`GPU=plain` remains broken for an unrelated reason:
`RenderEngine::validateOutputBufferUsage()` is a `LOG_ALWAYS_FATAL_IF` on
`USAGE_HW_RENDER`, so SurfaceFlinger aborts with "output buffer not gpu
writeable". No format change affects it.

---

### 5.4 GTK onto a forwarded X display

`DISPLAY_MODE=auto` used to treat any set `DISPLAY` as a local screen and pick
`gtk,gl=on`. Over SSH X11 forwarding (MobaXterm, PuTTY) that display is
forwarded, and `gtk,gl=on` is wrong twice over: `gl=on` wants a local GL
context, and GTK cannot find a `GdkMonitor` for a window it does not really
own, so QEMU's per-frame refresh-rate query fails on every frame:

```
qemu: Gdk: gdk_monitor_get_refresh_rate: assertion 'GDK_IS_MONITOR (monitor)' failed
```

The assertion is harmless in itself — a `g_return_if_fail` yielding a 0 refresh
rate — but it floods stdout, which `-serial mon:stdio` shares, so it interleaves
with the guest console and cuts log lines in half:

```
[    6.699643] servicemanager: Notifying media.codeclist.genqemu: Gdk: ...
erator they don't (previously: do) have clients ...
```

`auto` now detects the forwarded case (`SSH_CONNECTION` set, X11 rather than
Wayland) and resolves to VNC, which is the better remote answer regardless:
QEMU renders with `egl-headless` on the host GPU and ships finished frames
instead of pushing X11 traffic per frame. `DISPLAY_MODE=gtk` still forces the
window, and `gtk` carries `gl=on` explicitly — without it the plain GTK path
takes the non-GL scanout and shows the black-screen-with-a-cursor failure
of §5.2.

## 6. drm_hwcomposer

Ready as-is. Add to `device.mk`:

```make
PRODUCT_PACKAGES += com.android.hardware.graphics.composer.drm_hwcomposer

PRODUCT_VENDOR_PROPERTIES += \
    vendor.hwc.drm.device=/dev/dri/card0
```

Do **not** copy Cuttlefish's
`ro.vendor.hwc.drm.present_fence_not_reliable=true` or
`ro.vendor.hwcomposer.pmem=/dev/block/pmem1` — both are crosvm workarounds.
Real i915/amdgpu present fences are reliable.

Vendor backends exist for Imagination, HiSilicon, Amlogic and MediaTek.
**Intel and AMD need none** — the generic atomic KMS path covers them.

### Multi-display

`/dev/dri/card0` is hardcoded above. A laptop with an external monitor, or a
desktop with multiple outputs, will need connector enumeration work. Defer,
but know it is there.

---

## 7. Bring-up sequence

1. Kernel boots, `/dev/dri/card0` exists, `modetest` enumerates connectors
2. SwiftShader UI — display path proven without any GPU driver
3. minigbm `pc` platform builds and loads; gralloc allocations succeed
4. drm_hwcomposer composites — hardware planes, real vsync
5. Mesa GL (`iris` first — no LLVM dependency)
6. Mesa GL `radeonsi` (LLVM required)
7. Vulkan ANV, then RADV

Steps 1–4 are tractable. Step 5 is where the schedule risk lives.

---

## 8. Debugging

```bash
# on device
modetest -c                       # connectors, modes, planes
cat /sys/kernel/debug/dri/0/name  # which kernel driver bound
dumpsys SurfaceFlinger
logcat -s SurfaceFlinger:V hwc-drm:V gralloc:V

# Mesa
setprop vendor.mesa.debug 1
MESA_LOADER_DRIVER_OVERRIDE=iris   # force a driver
LIBGL_ALWAYS_SOFTWARE=1            # bisect GPU vs. stack
```

`dmesg | grep -iE 'i915|amdgpu|drm'` on the kernel side. AMD firmware load
failures are quiet — check explicitly.
