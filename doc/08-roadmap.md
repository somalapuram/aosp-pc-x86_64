# 08 — Roadmap

Staged so that **every phase ends with something that boots**. Nothing is
"integrate at the end".

---

## Phase 0 — Baseline (days) ✅ mostly done

- [x] AOSP 17 synced — 153 GB, `android17-release`
- [x] Mainline kernel cloned — v7.2-rc6
- [ ] Host build packages installed ([02](02-host-setup.md) §1)
- [ ] QEMU/OVMF/GRUB tooling installed
- [ ] `usermod -aG kvm,render,video`

**Exit:** toolchain ready.

---

## Phase 1 — Cuttlefish reference build (days)

Not your product. Your reference implementation and toolchain validation.

- [ ] `lunch aosp_cf_x86_64_phone-trunk_staging-userdebug && m -j192`
- [ ] Boot it under `launch_cvd`, confirm the tree is healthy
- [ ] **Read `device/google/cuttlefish/shared/` end to end**
- [ ] Catalogue what to keep vs. delete ([04](04-device-target.md) §1)

**Exit:** a working reference you understand, and a validated build host.

---

## Phase 2 — Kernel (1–2 weeks)

- [ ] Extract base config from the mainline Cuttlefish prebuilt
- [ ] Merge `kernel/configs/d/android-6.18/android-base.config`
- [ ] **Audit dropped symbols** — 6.18 fragments onto a 7.2 tree
- [ ] Add `i915`, `xe`, `amdgpu`, `virtio-gpu` (all `=y`)
- [ ] Add firmware via `CONFIG_EXTRA_FIRMWARE`
- [ ] `make -j192 bzImage`
- [ ] Boot to a kernel panic-on-no-init under QEMU

**Exit:** kernel boots in QEMU, `/dev/dri/card0` exists, `modetest` enumerates.

**Risk:** low. This phase is well-understood.

---

## Phase 3 — Device target, boot to shell (2–4 weeks)

- [ ] Create `device/pcx86/pc_x86_64/` ([04](04-device-target.md))
- [ ] AVB off, dynamic partitions off, raw ext4, GRUB on ESP
- [ ] `m -j192` completes
- [ ] GPT disk, images written, GRUB boots kernel + ramdisk
- [ ] `init` runs; `/system` and `/vendor` mount via `by-name`
- [ ] Serial console output; `adb` reachable
- [ ] `zygote` starts without a crash loop

**Exit:** `adb shell` on a bare-metal-style boot in QEMU.

**Risk:** medium. Mostly first-stage-mount and fstab debugging.

---

## Phase 4 — Boot to UI on SwiftShader (2–4 weeks)

Deliberately **before** Mesa, so graphics driver work is off the critical path.

- [ ] SwiftShader packages + `INSECURE_EXECMEM` sepolicy
- [ ] drm_hwcomposer wired, `vendor.hwc.drm.device=/dev/dri/card0`
- [ ] SurfaceFlinger composites; launcher renders
- [ ] Input working — keyboard, mouse, touchpad
- [ ] Boot on **real hardware** for the first time

**Exit:** software-rendered Android UI, on metal, with working input.

**Risk:** medium. This is the first genuinely satisfying milestone.

---

## Phase 5 — minigbm + Intel GPU (3–6 weeks)

- [ ] Add the `pc` platform to `external/minigbm/Android.bp` ([05](05-graphics.md) §3)
- [ ] `soong_config_set,minigbm,platform,pc`
- [ ] gralloc allocations succeed on `i915`
- [ ] drm_hwcomposer uses hardware planes and real vsync
- [ ] **Mesa `iris`** — Option A timeboxed to 1 week, then Option B
- [ ] Hardware-accelerated GL on Intel

**Exit:** accelerated Android on an Intel iGPU.

**Risk:** ~~**high**~~ — **done for Intel.** `iris` builds and runs; hardware GL
on Meteor Lake at GLES 3.2, 9.4x SwiftShader (README).

The stated reason for choosing `iris` first was wrong: in Mesa 26.1 it needs
LLVM as well, because `with_gallium_iris` is in `with_driver_using_cl` and that
forces CLC on. `-Dmesa-clc=system` is what avoids it, by keeping LLVM a
build-host dependency instead of a cross-compiled one. Intel-first was still the
right call — minigbm has an `i915` backend and `amdgpu.c` needs the DRI loader —
just not for the reason recorded here. See doc/05-graphics.md 4.

---

## Phase 6 — One image, every desktop GPU (2–4 weeks)

**Goal: the Ubuntu model.** A single image that boots on Intel, AMD or NVIDIA
and picks the right driver by itself. No per-vendor build, no user choice.

That is already how Mesa works. One `libgallium_dri.so` can carry `iris`,
`radeonsi`, `nouveau` and `virgl`, and the DRI loader selects between them at
runtime from the kernel driver name. The work is not "make a driver"; it is
"stop excluding three of them, and make gralloc allocate on all of them".

### What this phase costs was badly overestimated

The previous version of this phase said radeonsi "requires LLVM. Expect this to
be the hardest build problem in the project", with risk **high**, "concentrated
entirely in the LLVM dependency", needing LLVM cross-compiled for Android.

**That is no longer true and the correction is one meson flag.** In this Mesa:

- `meson.build:57` — `amd_with_llvm = with_llvm.allowed() and get_option('amd-use-llvm')`,
  so the LLVM requirement is *conditional*, not absolute.
- `radeonsi/si_pipe.c:663` — `#if !AMD_LLVM_AVAILABLE` sets `use_aco = 1` on
  every shader stage. ACO is Mesa's own AMD compiler backend, the one RADV has
  always used, and it needs no LLVM.

So `-Damd-use-llvm=false` alongside the existing `-Dllvm=disabled` gives a
working radeonsi. The hardest-problem-in-the-project framing was correct when
written and is now simply stale.

`nouveau` never needed LLVM at all — `nvc0` carries its own codegen.

### The actual work

- [x] Mesa builds `iris,radeonsi,nouveau,virgl` into one 41 MB `libgallium_dri.so`,
      verified to carry all four driver descriptors, `aco_compiler`, `amdgpu`,
      `nouveau_drm`, `nv50` and `nvc0`, and zero LLVM
- [x] libdrm cross-build enables `-Damdgpu=enabled -Dnouveau=enabled`
- [x] minigbm compiles `-DDRV_AMDGPU` and links `libdrm_amdgpu`
- [x] `CONFIG_DRM_NOUVEAU=y` with GSP defaults
- [x] `pc_select_egl.sh` sends i915, xe, amdgpu and nouveau to Mesa
- [x] **radeonsi builds**, on ACO, against a cross-built libelf. See below.
- [ ] Boot on AMD and confirm `GLES:` names radeonsi
- [ ] Boot on NVIDIA and confirm `GLES:` names nouveau

### radeonsi: the second blocker, and how it was cleared

`-Damd-use-llvm=false` works exactly as expected — meson gets past the LLVM
requirement. It then stops on a different one:

    ERROR: Problem encountered: Gallium driver radeonsi requires libelf

`src/amd/common/ac_rtld.c` includes `<gelf.h>` and `<libelf.h>` unconditionally
and is compiled into `ac_common` whatever the shader compiler is, so the libelf
check at `meson.build:2037` fires for any radeonsi build. libelf is not in the
NDK and Mesa has no `libelf.wrap` to fall back on.

Worth noting *why this looks wrong*: `USE_LIBELF` appears in exactly two places
in the tree, `ac_rgp.c` (Radeon GPU Profiler capture) and `radv_shader.c` (the
Vulkan driver, which this build does not compile). It appears nowhere in
radeonsi's own gallium code.

It is nevertheless real, and deleting the meson check would only have traded a
configure failure for a link failure: `src/amd/common/meson.build:206` does gate
`ac_rtld.c` behind `dep_elf.found()`, but `si_shader_binary.c` and
`si_debug_gfx_compute.c` call `ac_rtld_*` **unguarded**. So the answer was to
supply libelf, not to remove the requirement — and it leaves Mesa unpatched.

**`tools/build-mesa.sh` now cross-builds it** from `android_17/external/elfutils`,
which is already in the tree and already marked `vendor_available`. Three things
made it work, none of them obvious from the source alone:

- **`-include AndroidFixup.h` and `-I bionic-fixup`.** bionic has no
  `libintl.h` and no `error()`. elfutils ships stubs for both in
  `bionic-fixup/`, and `Android.bp`'s `android:` target block force-includes
  them. Without this, *every* file fails on `#include <libintl.h>` — which is
  what the first attempt did, silently, because the compile loop had
  `2>/dev/null || true` on it. That swallow is gone; a failed file is now fatal.
- **`-DHAVE_CONFIG_H -D_GNU_SOURCE -DNMNES=1000 -D_FILE_OFFSET_BITS=64
  -std=gnu99`**, copied from `elfutils_defaults`. `external/elfutils/config.h`
  is pre-made for Android, so no autoconf run is needed.
- **A two-line `config.h` shim that turns `USE_ZSTD` back off.** `elf_strptr()`
  — which `ac_rtld.c` calls — pulls in `elf_compress.c`, and the tree's
  `config.h` sets `USE_ZSTD 1`. There is no zstd in the NDK sysroot. Rather than
  cross-build all 26 files of `external/zstd` for a path that cannot execute
  (AMD shader ELFs are never compressed), the build drops a `config.h` earlier
  on the include path that does `#include_next <config.h>` and then `#undef
  USE_ZSTD`. zlib *is* in the sysroot, so `USE_ZLIB` stays on and the `.pc`
  carries `-lz`.

Result: 124 objects, a 292 KB `libelf.a`, a generated `libelf.pc`, and a
`libgallium_dri.so` that links `ac_rtld_open`/`ac_rtld_upload`/`elf_strptr`
with no undefined symbols. `strings` finds `aco_compiler`, `ACO_DEBUG`,
`radeonsi_dri` and the `GFX10`–`GFX125` family names, and zero `LLVM ERROR`.

Do not reach for zink-over-RADV as an escape: RADV's own libelf use is optional
(`#if defined(USE_LIBELF)`), so it would build, but it trades a known compile
problem for an extra translation layer and a second driver stack to debug.

**Still untested on hardware.** Everything above is build-level. The workstation
has an AMD Raphael iGPU at `17:00.0` and an NVIDIA GA104 at `01:00.0`, so both
paths can be tested on it.

The hardware test is short: boot, then `dumpsys SurfaceFlinger | grep GLES`
should name radeonsi on AMD and nouveau on NVIDIA. SurfaceFlinger not
crash-looping *is* the gralloc test — it aborts within seconds if it cannot get
a buffer.

### What NVIDIA needs that AMD does not

NVIDIA's blocker was never Mesa. `backend_nouveau` is already in minigbm's
dispatch list, unconditionally, built from `INIT_DUMB_DRIVER(nouveau)` — linear
dumb buffers, no tiling, but it allocates and scans out. Nothing had to be
added for it.

What it needs instead is **GSP firmware**. From Turing onward, display and
memory init live behind the GPU System Processor, and nouveau drives them by
handing it signed firmware. Without that the driver binds and then cannot light
a display — which reads as a nouveau bug and is not one. The blobs are tens of
MB per generation, so they go through the userspace firmware helper already
enabled for wifi, not `CONFIG_EXTRA_FIRMWARE`.

Expect NVIDIA to be **slower than AMD**, not equal. nouveau cannot reclock most
cards, so the GPU may sit at boot clocks. That is a driver limitation, not a
port bug, and it should be measured and stated rather than explained away.

### Test hardware

The development workstation has both vendors in one box:

    01:00.0  NVIDIA GA104 [GeForce RTX 3070 Ti]
    17:00.0  AMD Raphael integrated

So both halves can be tested by booting the USB image on the workstation
itself, with no extra hardware and no risk to the ZBook.

**On a two-GPU machine, check which node is which.** `card0` is probe order,
not preference. `pc_select_egl.sh` prefers integrated over discrete because on
a hybrid laptop the panel hangs off the integrated part, but a desktop with a
discrete card driving the monitor inverts that. If the display comes up blank
with a driver bound, that ordering is the first thing to check.

**Exit:** one image, hardware accelerated on Intel, AMD and NVIDIA, selecting
itself.

**Risk:** medium, and now concentrated in *runtime* rather than the build —
gralloc format/modifier negotiation per vendor, and GSP firmware on NVIDIA.
The build risk that dominated this phase for a year is gone.

---

## Phase 7 — HAL long tail (2–4 months)

Roughly parallelisable; audio and sepolicy dominate.

- [ ] SELinux vendor policy → enforcing
- [ ] Audio AIDL HAL over tinyalsa / `snd_hda_intel`
- [ ] Power, battery, lid, suspend/resume
- [ ] WiFi (`iwlwifi`), Bluetooth (Floss)
- [ ] Camera (UVC external HAL)
- [ ] VINTF manifest and feature XML correct

**Exit:** a usable machine.

**Risk:** medium, but **long**. Suspend/resume and audio mixer paths are the
usual sinkholes.

---

## Phase 8 — Hardening (open-ended, product goal only)

- [ ] Vulkan: ANV, then RADV
- [ ] AVB / verified boot, dm-verity
- [ ] Dynamic partitions, A/B, OTA
- [ ] `incremental-fs` ported to 7.2
- [ ] Recovery
- [ ] CTS/VTS

**Skip this phase entirely** if the goal is learning or kernel development.

---

## Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| **Mesa native drivers not buildable in AOSP** | 🔴 Critical | SwiftShader keeps it off the critical path (Phase 4 before 5). Option B (out-of-tree) as the real answer. |
| **LLVM dependency blocks `radeonsi`** | ⚪ Closed | Wrong premise. `-Damd-use-llvm=false` moves radeonsi to ACO; the real dependency was libelf, now cross-built from `external/elfutils`. `iris` still needs LLVM, but only on the build host (`-Dmesa-clc=system`). |
| **meson2hermetic fork unmaintained/incomplete** | 🟠 Medium | Hard 1-week timebox, then switch to Option B. |
| **6.18 fragments vs. 7.2 kernel drift** | 🟠 Medium | Audit dropped symbols explicitly. ACK `android16-6.18` as fallback. |
| **SELinux scope discovered late** | 🟠 Medium | Flip to enforcing early on a throwaway branch to size it. |
| **Audio mixer paths per machine** | 🟠 Medium | Target one specific machine first. Generalise later. |
| **Suspend/resume on metal** | 🟠 Medium | Cannot be validated in a VM. Schedule as explicit bare-metal work. |
| **NVIDIA-only test hardware** | 🔴 Critical | Not viable. Acquire Intel or AMD hardware before Phase 4. |

---

## The single most important sequencing decision

**Phase 4 (SwiftShader UI) comes before Phase 5 (Mesa).**

Mesa is a 1–3 month effort with genuine uncertainty. SwiftShader gets you a
booting, interactive Android UI on real hardware without it. That means:

- The HAL long tail (Phase 7) can start against a working display
- You have a demoable system months earlier
- If Mesa turns out to be a dead end on AOSP 17, you still have a working OS

Do not let the graphics work block the rest of the port.
