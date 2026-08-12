#
# Product definition for a bare-metal x86_64 PC.
#
# Modelled on device/google/cuttlefish/vsoc_x86_64_only/phone/aosp_cf.mk, with
# the crosvm-specific inherits removed. Telephony is omitted -- a PC has none.
#

# Must be set before the inherits below, and cannot live in BoardConfig.mk --
# it is readonly by the time board config is read.
PRODUCT_USE_DYNAMIC_PARTITIONS := false

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_system.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/handheld_system_ext.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_product.mk)

$(call inherit-product, device/pcx86/pc_x86_64/device.mk)

# generic_system.mk claims system/% as its artifact path. BoardConfig.mk folds
# system_ext and product into system/ to keep the disk to three partitions,
# which the enforcement reads as "device makefile produces files inside
# generic_system.mk's artifact path requirement".
#
# 'relaxed' does not help: build/soong/fsgen/artifact_path_requirements.go runs
# that check for every value except 'false'. Artifact path separation is GSI
# hygiene and this target is not a GSI, so turn it off outright.
PRODUCT_ENFORCE_ARTIFACT_PATH_REQUIREMENTS := false

PRODUCT_NAME := pc_x86_64
PRODUCT_DEVICE := pc_x86_64
PRODUCT_BRAND := Android
PRODUCT_MODEL := Android on PC x86_64
PRODUCT_MANUFACTURER := pcx86

# Keyboard-and-mouse machine: tablet characteristics give a sane default UI
# without the phone-specific telephony assumptions.
PRODUCT_CHARACTERISTICS := tablet
