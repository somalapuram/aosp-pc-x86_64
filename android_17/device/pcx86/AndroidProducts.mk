#
# Bare-metal x86_64 PC target for AOSP 17.
# See ~/amar/x86/doc/04-device-target.md
#

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/pc_x86_64/pc_x86_64.mk

COMMON_LUNCH_CHOICES := \
    pc_x86_64-trunk_staging-userdebug \
    pc_x86_64-trunk_staging-eng
