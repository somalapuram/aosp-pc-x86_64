#!/vendor/bin/sh
# No-op for init.rc's init_dev_config hook.
#
# 'service init_dev_config ${ro.vendor.init_dev_config.path}' cannot expand an
# unset property, and that failure takes ueventd and apexd-bootstrap with it:
#     Cannot expand path: property 'ro.vendor.init_dev_config.path' doesn't exist
#     reboot: ... 'bootloader,bootstrap-apexd-failed'
# so the property has to point at something carrying init_dev_config_exec.
# The GL driver choice is made by pc_select_egl.sh instead, because init never
# actually starts this hook on this device.
exit 0
