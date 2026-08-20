#
# Board configuration for a bare-metal x86_64 PC.
#
# Deliberately crippled for bring-up: every feature disabled here is one fewer
# variable when first boot fails. See doc/04-device-target.md and
# doc/06-boot-and-storage.md for what has to come back before this ships.
#

# --- Architecture ----------------------------------------------------------
TARGET_ARCH := x86_64
TARGET_ARCH_VARIANT := x86_64
TARGET_CPU_ABI := x86_64

TARGET_2ND_ARCH := x86
TARGET_2ND_ARCH_VARIANT := x86_64
TARGET_2ND_CPU_ABI := x86

# --- Kernel and bootloader -------------------------------------------------
# The kernel is built out of tree (~/amar/x86/linux, see doc/03-kernel.md) and
# GRUB lives on the ESP, so AOSP builds neither. GRUB loads bzImage and
# ramdisk.img directly -- doc/06-boot-and-storage.md option A.
TARGET_NO_BOOTLOADER := true
TARGET_NO_KERNEL := true
TARGET_NO_RECOVERY := true

# --- Bring-up simplifications ----------------------------------------------
# Verified boot needs a chain of trust from a bootloader we do not control on
# PC hardware. A/B adds moving parts we do not need yet.
#
# PRODUCT_USE_DYNAMIC_PARTITIONS is a product variable and is readonly by the
# time BoardConfig.mk is read -- it is set in pc_x86_64.mk instead.
BOARD_AVB_ENABLE := false
AB_OTA_UPDATER := false

# Fold product and system_ext into system so the disk needs three partitions
# rather than five. Revisit if/when dynamic partitions come back.
TARGET_COPY_OUT_PRODUCT := system/product
TARGET_COPY_OUT_SYSTEM_EXT := system/system_ext
TARGET_COPY_OUT_VENDOR := vendor

# --- Filesystems -----------------------------------------------------------
# Plain ext4 rather than erofs while bringing up: it is writable, which makes
# on-device debugging far easier.
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_SPARSE_EXT_DISABLED := false

BOARD_SYSTEMIMAGE_PARTITION_SIZE := 6442450944      # 6 GiB
BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4

BOARD_VENDORIMAGE_PARTITION_SIZE := 2147483648      # 2 GiB
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4

BOARD_FLASH_BLOCK_SIZE := 512

# Declares that this device has a /metadata partition, which makes the build
# create the /metadata mount point in the system image. Without it the
# directory does not exist and first-stage init dies while switching root:
#     init: Switching root to '/system'
#     init: Unable to move mount at '/metadata' to '/system/metadata':
#           No such file or directory
#     init: InitFatalReboot: signal 6
# The partition itself is created by tools/mkdisk.sh and mounted by
# fstab.pc_x86_64; aconfig flag storage lives there.
BOARD_USES_METADATA_PARTITION := true

# --- Graphics --------------------------------------------------------------
# Vulkan is provided in software by SwiftShader, with ANGLE on top for GLES.
# See device.mk for why both are needed.
TARGET_VULKAN_SUPPORT := true
TARGET_USES_VULKAN := true

# --- VINTF and SELinux -----------------------------------------------------
# manifest.xml  = what the vendor PROVIDES (empty; AIDL services ship their own
#                 vintf fragments -- see the file for why duplicating conflicts)
# compatibility_matrix.xml = what the vendor REQUIRES of the framework (empty,
#                 but the file must exist or checkvintf fails with
#                 "getDeviceCompatibilityMatrix: -2 ... No such file")
DEVICE_MANIFEST_FILE := device/pcx86/pc_x86_64/manifest.xml
DEVICE_MATRIX_FILE := device/pcx86/pc_x86_64/compatibility_matrix.xml
BOARD_VENDOR_SEPOLICY_DIRS += device/pcx86/pc_x86_64/sepolicy

# Private platform policy additions. Needed for the bpffs name transitions,
# which reference bpfloader and the fs_bpf_* types -- private platform types
# that vendor policy cannot see. See sepolicy/private/bpffs_name_transitions.te
# for why they are required on a mainline kernel.
SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += device/pcx86/pc_x86_64/sepolicy/private

# --- WiFi ------------------------------------------------------------------
# There is deliberately no vendor WiFi HAL here. That is a supported
# configuration rather than a gap: WifiNative has an explicit no-vendor-HAL
# path (handleIfaceCreationWhenVendorHalNotSupported, WifiNative.java), and
# everything this device needs -- scan, connect, WPA2/WPA3 -- goes through
# wpa_supplicant on nl80211 plus wificond, neither of which calls the vendor
# HAL. What is lost is the vendor-HAL-only surface: link-layer stats, RTT,
# Aware/NAN, tethered SoftAP and multi-iface concurrency.
#
# The alternative, android.hardware.wifi-service, is worse here: its vendor
# half is per-chip (libwifi-hal-bcm/-syna/-qcom/...), and with BOARD_WLAN_DEVICE
# unset it links libwifi-hal-fallback, whose every entry point returns
# NOT_SUPPORTED. IWifi.start() then fails and the framework reports a broken
# HAL -- strictly worse than not declaring one. libwifi-hal-desktop looks by
# name like the right answer for this device, but it is only REFERENCED in
# frameworks/opt/net/wifi/libwifi_hal/Android.bp; no module of that name exists
# in this tree, so BOARD_WLAN_DEVICE := desktop does not link.
#
# Soong reads all of these through
# external/wpa_supplicant_8/board_config_wpa_supplicant.mk, which
# build/make/core/board_config.mk includes.
BOARD_WPA_SUPPLICANT_DRIVER := NL80211

# REQUIRED, and easy to miss: in wpa_supplicant/Android.bp the supplicant's
# init_rc sits inside a soong_config_variables block gated on exactly this
# variable. Without it wpa_supplicant still builds and still installs to
# /vendor/bin/hw/wpa_supplicant -- with no init service anywhere. Nothing ever
# starts it, and the failure presents as the supplicant HAL being dead rather
# than as a missing .rc.
WIFI_HIDL_UNIFIED_SUPPLICANT_SERVICE_RC_ENTRY := true

# The bring-up laptop's card is an AX211 (Wi-Fi 6E), so build the 11ax paths.
WIFI_FEATURE_SUPPLICANT_11AX := true

# BOARD_WPA_SUPPLICANT_PRIVATE_LIB is intentionally left unset. It names a
# per-vendor driver-command shim (cuttlefish uses lib_driver_cmd_simulated_cf_bp
# for mac80211_hwsim); empty selects the stub, which is what a generic nl80211
# driver such as iwlwifi wants. Same for BOARD_HOSTAPD_* -- no SoftAP without a
# vendor HAL, so hostapd is not built.
