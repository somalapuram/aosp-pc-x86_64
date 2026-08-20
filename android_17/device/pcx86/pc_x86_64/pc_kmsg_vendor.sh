#!/system/bin/sh
#
# Capture the kernel log. Runs in vendor_shell, not shell, and that is the
# whole point of its existence.
#
# Reading /dev/kmsg needs two gates open:
#   1. dmesg_restrict=0, set from the kernel command line (tools/mkdisk.sh),
#      because it otherwise needs CAP_SYSLOG.
#   2. SELinux syslog_read, because devkmsg_open still calls security_syslog()
#      even when dmesg_restrict is 0.
#
# The second cannot be granted to shell at any price:
#     neverallow appdomain kernel:system { syslog_read syslog_mod syslog_console };
# and shell is an appdomain. So the capture cannot live in pc_kmsg_file.sh with
# the rest of the bring-up dumps; it needs a domain that is not an app.
# vendor_shell already exists here for pc_select_egl and is not an appdomain.
#
# On a machine with no serial header and no network this is the only way to see
# which drivers bound, what firmware was requested, and why a device did not
# appear.
OUT=/data/vendor/pc/kmsg.txt
PREV=/data/vendor/pc/kmsg.prev.txt

[ -f "$OUT" ] && mv -f "$OUT" "$PREV"
exec cat /dev/kmsg >> "$OUT"
