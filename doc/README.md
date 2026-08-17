# Android 17 on Bare-Metal x86_64 — Intel iGPU + AMD GPU

Project documentation for porting AOSP 17 to real x86_64 PC hardware with
hardware-accelerated graphics on Intel integrated GPUs and AMD GPUs.

**Not** Cuttlefish. **Not** the Android emulator. **Not** Android-x86.
A new device port, built against the AOSP 17 tree.

---

## Status of the working tree

Paths below are relative to the repository root. Neither upstream tree is
committed; `./build.sh sync` fetches both at the revisions recorded here, and
the top-level [README](../README.md) covers that.

Shell snippets throughout these documents write `$REPO` for the repository
root, so they can be pasted after:

```sh
export REPO=$(pwd)      # from the top of the clone
```

| Item | Value |
|---|---|
| AOSP | `android_17/`, `android17-release`, pinned per-project in `manifests/` |
| Mainline kernel | `linux/`, **v7.2-rc6** (`0d8395707651`, 2026-08-05), unmodified |
| Android Common Kernel target | **android-6.18** (`kernel/configs/d/android-6.18/`) |
| Build host used | 192 cores, 246 GB RAM, 3.2 TB free, `/dev/kvm` present |

---

## Read these in order

| # | Document | What it covers |
|---|---|---|
| 01 | [Scope and tree audit](01-scope-and-findings.md) | What AOSP 17 actually gives you, the three real gaps, honest effort estimate |
| 02 | [Host and dev VM setup](02-host-setup.md) | Build deps, QEMU/KVM configured as a *generic PC*, VFIO passthrough |
| 03 | [Kernel changes required](03-kernel.md) | Verified gap analysis vs. mainline 7.2, full required config, i915/xe/amdgpu |
| 04 | [Device target](04-device-target.md) | Creating `device/pcx86/pc_x86_64` from the Cuttlefish template |
| 05 | [Graphics](05-graphics.md) | **The hard part.** minigbm, drm_hwcomposer, Mesa for Intel/AMD |
| 06 | [Boot and storage](06-boot-and-storage.md) | UEFI, GRUB, GPT, ext4, disabling AVB for bring-up |
| 07 | [HAL long tail](07-hals.md) | Audio, input, WiFi, BT, power, camera, SELinux |
| 08 | [Roadmap](08-roadmap.md) | Phases, milestones, risk register |

---

## Executive summary

**The good part.** AOSP 17 contains the full *source* for a bare-metal DRM/KMS
graphics stack — `external/minigbm` (with `i915.c`, `xe.c`, `amdgpu.c`),
`external/drm_hwcomposer` (HWC3 AIDL service + APEX), `external/libdrm` (with
buildable `libdrm_intel` and `libdrm_amdgpu`), and the complete
`external/mesa3d` source tree including `iris`, `radeonsi`, ANV and RADV.
Cuttlefish already drives a genuine DRM/KMS path through `/dev/dri/card0`, so
the device-config plumbing exists and can be copied rather than invented.

**The bad part.** Source presence is not build wiring. Three concrete gaps:

1. **Mesa builds no native GPU drivers.** `external/mesa3d/Android.bp` is 701
   lines and produces only gfxstream/virtgpu guest modules. No `iris`, no
   `radeonsi`, no ANV, no RADV, no `llvmpipe`. This is the single largest work
   item in the project and it is on the critical path.
2. **minigbm has no AMD platform.** Intel is wired
   (`soong_config_variable("minigbm", "platform")` → `intel` →
   `-DDRV_I915 -DDRV_XE`). `amdgpu.c` and `backend_amdgpu` exist but nothing
   defines `-DDRV_AMDGPU`. You must add the platform.
3. **No bare-metal x86 device target exists.** `device/generic/x86_64` is a
   skeleton with `TARGET_NO_KERNEL` and `TARGET_NO_BOOTLOADER`. You write the
   device port.

Full evidence with file references in [01-scope-and-findings.md](01-scope-and-findings.md).

**Kernel.** No out-of-tree kernel code is required to boot — the port is a
configuration exercise plus GPU enablement. Seven Android-specific Kconfig
symbols are absent from mainline 7.2 (`ASHMEM`, `DM_DEFAULT_KEY`,
`CPU_FREQ_TIMES`, `UID_SYS_STATS`, `NETFILTER_XT_MATCH_QUOTA2`,
`INCREMENTAL_FS`, `DM_USER`) and **none of them block boot**.

Note that `kernel/configs/d/android-6.18/android-base.config` — the Android 17
fragment — is an **empty placeholder**. Use the populated `b/android-6.12`
fragment (261 lines) as the requirements baseline instead. Full verified gap
analysis in [03-kernel.md](03-kernel.md).

**Development vehicle.** QEMU/KVM configured as a *generic PC* — q35, OVMF
UEFI, GPT disk, GRUB, `virtio-vga-gl` for a real DRM/KMS node, `intel-hda` for
real ALSA. Exercises the true boot and DRM paths at seconds-per-iteration.
VFIO GPU passthrough for real i915/amdgpu testing without leaving the desk.
VirtualBox cannot boot any guest on this host, tested including a stock Alpine
ISO. See [02-host-setup.md](02-host-setup.md).

---

## Scope warning

This is a multi-month project for one person. AOSP has had no supported
bare-metal x86 target for years, and every guardrail for this path has been
removed. The tree gives you far more raw material than Android-x86 ever had,
but you are assembling it yourself.

The roadmap is staged so that each phase produces something that boots.
