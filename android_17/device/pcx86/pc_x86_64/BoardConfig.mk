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
