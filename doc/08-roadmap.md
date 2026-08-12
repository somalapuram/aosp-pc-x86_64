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

**Risk:** **high.** The Mesa build is the schedule risk in this project.
`iris` is chosen first specifically because it has no LLVM dependency.

---

## Phase 6 — AMD GPU (3–6 weeks)

- [ ] `-DDRV_AMDGPU` path validated against `libdrm_amdgpu`
- [ ] amdgpu firmware loading confirmed (fails quietly — check `dmesg`)
- [ ] **Mesa `radeonsi`** — requires LLVM. Expect this to be the hardest build
      problem in the project.
- [ ] Single image auto-selects Intel or AMD by PCI ID

**Exit:** one image, accelerated on both vendors.

**Risk:** **high**, concentrated entirely in the LLVM dependency.

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
| **LLVM dependency blocks `radeonsi`** | 🔴 High | Ship Intel-only first. `iris` needs no LLVM. AMD becomes a second pass. |
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
