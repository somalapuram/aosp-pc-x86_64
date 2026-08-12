# 04 — Device Target

Creating `device/pcx86/pc_x86_64` — a bare-metal x86_64 Android device
supporting Intel iGPU and AMD GPU.

---

## 1. Strategy: fork Cuttlefish, then cut the cord

Do **not** start from `device/generic/x86_64`. It is a vestigial skeleton
(`TARGET_NO_KERNEL := true`, inherits from an ARMv7 minimal config, no HALs).

Start from `device/google/cuttlefish/shared/`. It is the most complete
modern AIDL-HAL device in the tree, and critically its graphics path is
already real DRM/KMS through `/dev/dri/card0`. You are changing the backend
behind that node, not the architecture above it.

### What to keep from Cuttlefish

- `shared/device.mk` structure and HAL package lists
- `shared/graphics/` — minigbm + drm_hwcomposer wiring
- `shared/sepolicy/` — an enormous head start on vendor policy
- `shared/config/` — init.rc patterns, property layout
- `shared/permissions/` — feature XML declarations

### What to delete

- All goldfish/ranchu emulation: `libEGL_emulation`, `libGLESv2_enc`,
  `libGLESv1_enc`, `lib_renderControl_enc`, `libOpenglCodecCommon`,
  `com.android.hardware.graphics.composer.ranchu`, `libGoldfishProfiler`
- `shared/virgl/` — virtio-gpu specific
- crosvm/vsock transport HALs (`cuttlefish_vmm` dependencies)
- `ro.vendor.hwcomposer.pmem=/dev/block/pmem1` — a crosvm artifact
- Cuttlefish's telephony/GNSS/camera simulators unless you want stubs

---

## 2. Directory layout

```
device/pcx86/
├── AndroidProducts.mk
└── pc_x86_64/
    ├── BoardConfig.mk
    ├── device.mk
    ├── pc_x86_64.mk
    ├── fstab.pc_x86_64
    ├── init.pc_x86_64.rc
    ├── ueventd.pc_x86_64.rc
    ├── manifest.xml
    ├── overlay/
    ├── permissions/
    └── sepolicy/
```

---

## 3. `AndroidProducts.mk`

```make
PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/pc_x86_64/pc_x86_64.mk

COMMON_LUNCH_CHOICES := \
    pc_x86_64-trunk_staging-userdebug
```

Then `lunch pc_x86_64-trunk_staging-userdebug`.

---

## 4. `BoardConfig.mk`

Deliberately crippled for bring-up. Every disabled feature is one fewer
variable when the first boot fails.

```make
TARGET_ARCH := x86_64
TARGET_ARCH_VARIANT := x86_64
TARGET_CPU_ABI := x86_64
TARGET_2ND_ARCH := x86
TARGET_2ND_ARCH_VARIANT := x86_64
TARGET_2ND_CPU_ABI := x86

TARGET_USES_64_BIT_BINDER := true

# --- Bring-up simplifications: revisit all of these later ---
BOARD_AVB_ENABLE := false                  # no verified boot yet
TARGET_NO_RECOVERY := true                 # no recovery partition yet
BOARD_USES_RECOVERY_AS_BOOT := false
PRODUCT_USE_DYNAMIC_PARTITIONS := false    # no super.img — raw partitions
AB_OTA_UPDATER := false                    # no A/B

# Raw ext4 partitions, sized for the QEMU disk in 02-host-setup.md
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_SPARSE_EXT_DISABLED := false
BOARD_SYSTEMIMAGE_PARTITION_SIZE  := 6442450944   # 6 GiB
BOARD_VENDORIMAGE_PARTITION_SIZE  := 2147483648   # 2 GiB
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_FLASH_BLOCK_SIZE := 512

# Kernel supplied externally — see 03-kernel.md
TARGET_NO_KERNEL := false
TARGET_NO_BOOTLOADER := true               # GRUB lives on the ESP

# --- Graphics: see 05-graphics.md ---
BOARD_VENDOR_SEPOLICY_DIRS += device/pcx86/pc_x86_64/sepolicy
```

> ⚠️ `BOARD_AVB_ENABLE := false` and `PRODUCT_USE_DYNAMIC_PARTITIONS := false`
> are **bring-up only**. Both must come back before anything ships. Turning
> them on later is real work — budget for it.

---

## 5. `pc_x86_64.mk`

```make
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base.mk)
$(call inherit-product, device/pcx86/pc_x86_64/device.mk)

PRODUCT_NAME    := pc_x86_64
PRODUCT_DEVICE  := pc_x86_64
PRODUCT_BRAND   := Android
PRODUCT_MODEL   := Android on PC x86_64
PRODUCT_CHARACTERISTICS := tablet
```

`tablet` characteristics give you a sane default UI for a
keyboard-and-mouse machine without the phone-specific telephony assumptions.

---

## 6. `fstab.pc_x86_64`

No dm-verity, no logical partitions, during bring-up:

```
# <src>                  <mnt_point> <type> <mnt_flags>            <fs_mgr_flags>
/dev/block/by-name/system   /         ext4   ro,barrier=1           wait,first_stage_mount
/dev/block/by-name/vendor   /vendor   ext4   ro,barrier=1           wait,first_stage_mount
/dev/block/by-name/data     /data     ext4   noatime,nosuid,nodev   wait,check,formattable
```

`by-name` requires GPT partition labels matching those names — see
[06-boot-and-storage.md](06-boot-and-storage.md).

---

## 7. Kernel and ramdisk integration

`TARGET_NO_BOOTLOADER := true` because GRUB lives on the ESP rather than
being built by AOSP. You have two options for getting the kernel in:

**Option A (recommended for bring-up)** — keep the kernel entirely outside
AOSP. GRUB loads `bzImage` and `ramdisk.img` from the ESP directly. Rebuild
the kernel independently and just copy the new `bzImage` to the ESP. Fastest
iteration.

**Option B** — set `TARGET_PREBUILT_KERNEL := device/pcx86/kernel/bzImage`
and let AOSP package a `boot.img`. More Android-canonical, needed eventually
for AVB and OTA, but slower to iterate on now.

Start with A. Move to B when you turn AVB back on.

---

## 8. Bring-up order inside this phase

1. **Build it.** Get `m -j192` to complete. Expect many missing-HAL errors;
   stub aggressively.
2. **Boot to `init`.** Kernel + ramdisk, no `/system` mount. Serial console.
3. **Mount `/system` and `/vendor`.** First-stage mount, `by-name` symlinks.
4. **Reach `adb` over USB or Ethernet.** From here debugging gets far easier.
5. **Reach `zygote`** without a crash loop. `logcat` becomes available.
6. **Boot to UI on SwiftShader** — software rendering, no GPU driver needed.
   See [05-graphics.md](05-graphics.md) §5.

Milestone 6 is your Phase-2 exit criterion, and it deliberately does **not**
depend on Mesa.
