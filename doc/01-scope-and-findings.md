# 01 — Scope and Tree Audit

Findings from a direct audit of `$REPO/android_17` (android17-release).
Every claim below has a verification command. Re-run them if the tree changes.

---

## 1. There is no bare-metal x86 target

`device/generic/x86_64/` contains four files. The whole product is:

```make
# device/generic/x86_64/mini_x86_64.mk
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, device/generic/armv7-a-neon/mini_common.mk)
PRODUCT_NAME := mini_x86_64
```

And the board config:

```make
# device/generic/x86_64/BoardConfig.mk
TARGET_NO_BOOTLOADER := true
TARGET_NO_KERNEL := true
BUILD_EMULATOR := false
TARGET_USERIMAGES_USE_EXT4 := true
BOARD_USE_LEGACY_UI := true
```

No graphics, no HALs, no kernel, no bootloader. It inherits from an *ARMv7*
minimal common config. This is a vestigial build-system test target, not a
device.

The only x86_64 products that actually boot are Cuttlefish
(`aosp_cf_x86_64_*`) and the goldfish emulator. Both are virtual devices.

**Conclusion:** you are writing a new device port. See [04-device-target.md](04-device-target.md).

```bash
# verify
ls device/generic/x86_64/
cat device/generic/x86_64/BoardConfig.mk
```

---

## 2. Cuttlefish is a usable reference, not a competitor

Cuttlefish drives a real DRM/KMS pipeline. From
`device/google/cuttlefish/shared/graphics/device_vendor.mk`:

```make
PRODUCT_PACKAGES += com.android.hardware.graphics.composer.drm_hwcomposer
PRODUCT_PACKAGES += android.hardware.graphics.allocator-service.minigbm
PRODUCT_PACKAGES += mapper.minigbm
PRODUCT_VENDOR_PROPERTIES += vendor.hwc.drm.device=/dev/dri/card0
PRODUCT_VENDOR_PROPERTIES += ro.vendor.hwc.drm.present_fence_not_reliable=true
```

That is genuine minigbm gralloc + drm_hwcomposer over a real DRM node. The
difference from bare metal is the *backend* behind `/dev/dri/card0`
(virtio-gpu vs i915/amdgpu), not the architecture.

`device/google/cuttlefish/shared/` is the most complete example of a modern
AIDL-HAL Android device in the tree. Read it end to end before writing your
own device directory — it is the answer key.

Note the same makefile also pulls in goldfish/ranchu emulation libraries
(`libEGL_emulation`, `libGLESv2_enc`, `com.android.hardware.graphics.composer.ranchu`).
Those are the crosvm-specific parts you delete.

---

## 3. Graphics stack: source vs. build wiring

This is the critical section. **Sources are present; Soong build wiring for
native GPUs is largely absent.**

### 3.1 libdrm — OK

`external/libdrm/Android.bp` builds only core `libdrm`, but the
per-driver subdirectories carry their own Soong files and are picked up by
the normal Android.bp tree walk:

| Module | Path |
|---|---|
| `libdrm_amdgpu` | `external/libdrm/amdgpu/Android.bp` |
| `libdrm_intel` | `external/libdrm/intel/Android.bp` |
| `libdrm_radeon` | `external/libdrm/radeon/Android.bp` |

**No work needed.** These are buildable as-is.

```bash
# verify
grep -E '^\s*name:' external/libdrm/{amdgpu,intel,radeon}/Android.bp
```

### 3.2 minigbm — Intel wired, AMD not wired

Backend selection is a Soong config variable in `external/minigbm/Android.bp`:

```blueprint
intel_cflags = [
    "-DDRV_I915",
    "-DDRV_XE",
]
...
] + select(soong_config_variable("minigbm", "platform"), {
    "generic": generic_cflags,
    "intel":   intel_cflags,
    "meson":   meson_cflags,
    "msm":     msm_cflags,
    "mt8186":  mediatek_cflags + ["-DMTK_MT8186"],
    "mt8188":  mediatek_cflags + ["-DMTK_MT8188G"],
    "mt8196":  mediatek_cflags + ["-DMTK_MT8196"],
    default:   [],
}),
```

The available platforms are `generic`, `intel`, `meson`, `msm`, and three
MediaTek SoCs. **There is no `amdgpu` platform.**

Meanwhile the AMD backend source is fully present and wired into the driver
table:

```c
/* external/minigbm/drv.c:31 */
#ifdef DRV_AMDGPU
extern const struct backend backend_amdgpu;
#endif
```

```c
/* external/minigbm/amdgpu.c:6 */
#ifdef DRV_AMDGPU
#include <amdgpu.h>
```

`-DDRV_AMDGPU` is defined only by the ChromeOS `Makefile`, never by Soong.

**Work item:** add an AMD platform (or a combined `intel_amd` platform, since
you want one image supporting both) to `external/minigbm/Android.bp`. The
AMD backend links against `libdrm_amdgpu`, which is buildable per §3.1.
Details in [05-graphics.md](05-graphics.md).

```bash
# verify
grep -n 'DRV_AMDGPU' external/minigbm/*.c external/minigbm/Android.bp
sed -n '73,112p' external/minigbm/Android.bp
```

### 3.3 drm_hwcomposer — OK

`external/drm_hwcomposer/Android.bp` builds a complete HWC3 AIDL service and
an APEX:

- `android.hardware.composer.hwc3-service.drm`
- `drm_hwcomposer_hwc3`, `drm_hwcomposer_common`, `drm_hwcomposer_fd`
- APEX support: `drm_hwcomposer_hwc3_apex_manifest`, `..._vintf`, `..._init_rc`

Vendor-specific backends exist for Imagination, HiSilicon, Amlogic and
MediaTek. **Intel and AMD need no special backend** — they use the generic
DRM/KMS path, which is what Cuttlefish exercises today.

Last snapshot: 2026-03-27 (26Q2-release). **No work expected here.**

### 3.4 Mesa — the big gap

`external/mesa3d/` contains the **complete** upstream source tree:

- `src/gallium/drivers/`: `iris`, `crocus`, `radeonsi`, `r600`, `llvmpipe`,
  `softpipe`, `zink`, `virgl`, and more
- `src/intel/` (ANV Vulkan), `src/amd/` (RADV Vulkan)

But the checked-in `Android.bp` is **701 lines** and builds **none of them**.
Every module it produces is a gfxstream/virtio guest component:

```
mesa_gfxstream_virtgpu          mesa_platform_virtgpu
mesa_gfxstream_guest_android    mesa_goldfish_address_space
mesa_gfxstream_connection_manager
mesa_gfxstream_guest_iostream   virtgpu_kumquat_ffi_headers_mesa3d
```

Module type counts: 11 `cc_defaults`, 7 `cc_library_headers`, 4
`cc_library_static`, 2 `rust_defaults`. There is not one `cc_library_shared`
producing a DRI or Vulkan driver.

AOSP 17's Mesa integration exists **solely to serve the virtualized guest
path**. Native Intel and AMD drivers are not built by the Android build system
at all.

`README.aosp.md` explains why — the file is machine-generated:

> AOSP leverages [meson2hermetic] to provide autogenerated `Android.bp` files.
> ```sh
> git clone -b meson2hermetic https://github.com/gurchetansingh/mesonbuild.git
> cd main/external/mesa3d
> python3 ~/meson/meson.py convert android aosp_mesa3d
> ```

The `aosp_mesa3d` preset is **not in the tree** — it comes from that external
meson fork. Regenerating with different driver options is the documented path,
but it depends on a third-party fork of meson.

**This is the largest work item in the project.** Options and trade-offs in
[05-graphics.md](05-graphics.md).

```bash
# verify
wc -l external/mesa3d/Android.bp
grep -E '^\s*name:' external/mesa3d/Android.bp | sed 's/.*name: *//'
grep -cE 'iris|radeonsi|anv|radv|llvmpipe' external/mesa3d/Android.bp   # → 0
ls external/mesa3d/src/gallium/drivers/
```

### 3.5 SwiftShader — available, and it unblocks bring-up

`external/swiftshader/` is present with a working `Android.bp`
(`swiftshader_common`, `swiftshader_platform_headers`, …). SwiftShader is a
pure-software Vulkan/GLES implementation requiring no GPU at all.

Cuttlefish uses it via
`device/google/cuttlefish/shared/swiftshader/`:

```make
BOARD_VENDOR_SEPOLICY_DIRS += device/google/cuttlefish/shared/swiftshader/sepolicy
PRODUCT_REQUIRES_INSECURE_EXECMEM_FOR_SWIFTSHADER := true
```

**This is your Phase 2 unblock.** You can boot to a full Android UI on bare
metal with software rendering while Mesa is still unresolved, which takes the
Mesa work off the critical path for first boot. Note the `INSECURE_EXECMEM`
requirement — it needs a matching SELinux exception.

---

## 4. Summary table

| Layer | Source | AOSP build wiring | Work |
|---|---|---|---|
| libdrm core | ✅ | ✅ `libdrm` | none |
| libdrm intel/amdgpu | ✅ | ✅ `libdrm_intel`, `libdrm_amdgpu` | none |
| minigbm — Intel | ✅ | ✅ `platform:intel` → `-DDRV_I915 -DDRV_XE` | none |
| minigbm — AMD | ✅ `amdgpu.c` | ❌ no platform defines `-DDRV_AMDGPU` | **add platform** |
| drm_hwcomposer | ✅ | ✅ HWC3 AIDL service + APEX | none |
| Mesa GL (iris/radeonsi) | ✅ | ❌ not built | **large** |
| Mesa Vulkan (ANV/RADV) | ✅ | ❌ not built | **large** |
| SwiftShader (software) | ✅ | ✅ | none — bring-up fallback |
| Device target | — | ❌ skeleton only | **write it** |
| Bootloader | — | ❌ none in tree | **supply GRUB** |

---

## 5. Honest effort estimate

| Phase | Scope | Rough effort (one person) |
|---|---|---|
| Host + dev VM | Build deps, QEMU-as-PC harness | days |
| Kernel | mainline 7.2 + Android fragments | 1–2 weeks |
| Device target + boot to shell | New `device/`, GRUB, ext4, AVB off | 2–4 weeks |
| Boot to UI on SwiftShader | Software-rendered Android | 2–4 weeks |
| **Mesa native GL/Vulkan** | **iris + radeonsi + ANV + RADV** | **1–3 months** |
| HAL long tail | Audio, WiFi, BT, power, sepolicy | 2–4 months |
| Bare-metal hardening | ACPI, suspend, real firmware | open-ended |

The Mesa row is the one most likely to blow past its estimate. It depends on a
third-party meson fork or an out-of-tree build pipeline, and neither path is
well-trodden for AOSP 17 specifically.

Everything before it is tractable and well-understood.
