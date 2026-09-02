#!/system/bin/sh
#
# Persist the kernel log to /data so a boot on real hardware can be diagnosed.
#
# On a physical machine there is no virtio-console and usually no serial port
# to hand, so the kernel ring buffer is lost on power-off. That buffer is
# where the answers live for a display that never lights up: which DRM driver
# bound (i915 / xe / amdgpu / nouveau / none), whether its firmware loaded,
# which connectors were found and what modes they advertise.
#
# `dmesg -w` follows the buffer, so messages that arrive after this starts are
# captured too -- a snapshot would miss anything that goes wrong later.
# Everything already in the ring buffer at start is included as well, so no
# early boot output is lost by starting late.
#
# Read it afterwards on a workstation; userdata is plain ext4:
#     sudo mount -o ro /dev/sdX5 /mnt && less /mnt/kmsg.txt
# or use tools/collect-logs.sh, which does that and summarises the result.

OUT=/data/local/tmp/kmsg.txt
PREV=/data/local/tmp/kmsg.prev.txt

[ -f "$OUT" ] && mv -f "$OUT" "$PREV"

# Record the network address too. If the machine has a working NIC this is how
# to reach it with `adb connect <ip>:5555` instead of moving the disk around.
{
    echo "=== interfaces at $(date) ==="
    ip addr show 2>/dev/null | grep -E '^[0-9]+:|inet '
    echo "=== adb ==="
    echo "service.adb.tcp.port = $(getprop service.adb.tcp.port)"
    echo "init.svc.adbd        = $(getprop init.svc.adbd)"
    # USB device-mode. This is the one fact that decides whether USB adb is
    # possible at all: a gadget needs a UDC to bind to, and if /sys/class/udc
    # is empty there is no device controller and no amount of Android
    # configuration will produce one. dwc3 is enabled in the kernel fragment to
    # drive Intel's xDCI if this machine exposes it; these lines say whether it
    # probed.
    echo "=== usb device mode ==="
    echo "udc devices          = $(ls /sys/class/udc/ 2>/dev/null | tr '\n' ' ')"
    echo "ro.usb.controller    = $(getprop ro.usb.controller)"
    echo "sys.usb.controller   = $(getprop sys.usb.controller)"
    echo "sys.usb.config       = $(getprop sys.usb.config)"
    echo "sys.usb.state        = $(getprop sys.usb.state)"
    echo "dwc3 in dmesg        = $(dmesg 2>/dev/null | grep -ci dwc3)"
    echo "xdci/typec in dmesg  = $(dmesg 2>/dev/null | grep -ciE 'xdci|typec|ucsi')"
    echo "=== graphics ==="
    echo "ro.hardware.egl      = $(getprop ro.hardware.egl)"
    echo "ro.hardware.vulkan   = $(getprop ro.hardware.vulkan)"
    ls -l /dev/dri/ 2>&1
        # PCI inventory, straight from sysfs.
    #
    # This exists because the kernel log is not reachable: dmesg_restrict gates
    # both syslog(2) and /dev/kmsg behind CAP_SYSLOG, and shell -- an appdomain
    # -- may hold no capability at all. On a machine with no network and no
    # serial header that left every hardware question unanswerable.
    #
    # sysfs needs no capability. Each PCI device exposes its IDs and, crucially,
    # a "driver" symlink that exists only once something has BOUND to it. So
    # this distinguishes the two cases that look identical from Android:
    # hardware absent, versus hardware present with no driver.
    echo "=== PCI devices (vendor:device class driver) ==="
    for d in /sys/bus/pci/devices/*; do
        [ -e "$d/vendor" ] || continue
        v=$(cat "$d/vendor" 2>/dev/null)
        i=$(cat "$d/device" 2>/dev/null)
        c=$(cat "$d/class" 2>/dev/null)
        drv=$(readlink "$d/driver" 2>/dev/null)
        echo "  $(basename "$d")  ${v#0x}:${i#0x}  class=${c#0x}  driver=${drv##*/}"
    done
    echo "=== USB devices (vendor:product driver product) ==="
    # The interface's driver symlink, not the device's: btusb and usbhid bind to
    # interfaces. This is what says whether the Bluetooth radio and the touchpad
    # actually got a driver, as opposed to merely being present.
    for d in /sys/bus/usb/devices/*; do
        [ -e "$d/idVendor" ] || continue
        drv=""
        for i in "$d"/*:*; do
            [ -e "$i/driver" ] && drv="$drv $(basename "$(readlink "$i/driver")")"
        done
        echo "  $(basename "$d")  $(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null) drv=[${drv# }] $(cat "$d/product" 2>/dev/null)"
    done
    echo "=== bluetooth / wifi state ==="
    echo "  hci:  $(ls /sys/class/bluetooth/ 2>/dev/null | tr '\n' ' ')"
    echo "  net:  $(ls /sys/class/net/ 2>/dev/null | tr '\n' ' ')"
    echo "  ieee80211: $(ls /sys/class/ieee80211/ 2>/dev/null | tr '\n' ' ')"
    echo "=== why the kernel log may still be unreadable ==="
    echo "  dmesg_restrict = $(cat /proc/sys/kernel/dmesg_restrict 2>/dev/null || echo '<unreadable>')"
    echo "  /dev/kmsg perms: $(ls -l /dev/kmsg 2>/dev/null)"
    echo "  id: $(id 2>/dev/null)"
    echo "=== input devices ==="
    for d in /sys/class/input/input*; do
        [ -e "$d/name" ] && echo "  $(basename "$d")  $(cat "$d/name" 2>/dev/null)"
    done
    echo "=== video4linux ==="
    for d in /sys/class/video4linux/*; do
        [ -e "$d/name" ] && echo "  $(basename "$d")  $(cat "$d/name" 2>/dev/null)"
    done
    echo "=== net ==="
    ls /sys/class/net/ 2>/dev/null | tr '\n' ' '; echo

    # Power supplies, with the REAL /sys/devices path behind each symlink.
    #
    # The path is the point. sepolicy/genfs_contexts has to label the concrete
    # /devices/... directory, because /sys/class/power_supply holds symlinks and
    # SELinux checks the label of the inode they resolve to. Those paths are
    # ACPI-topology dependent and cannot be read off a powered-down disk, so
    # they are printed here rather than guessed a second time -- if healthd
    # still reports "No battery devices found", compare what genfs_contexts
    # labels against what this prints.
    echo "=== power supply (name : type : real path) ==="
    for d in /sys/class/power_supply/*; do
        [ -e "$d" ] || continue
        echo "  $(basename "$d") : $(cat "$d/type" 2>/dev/null) : $(readlink -f "$d" 2>/dev/null)"
    done
    echo "=== backlight ==="
    for d in /sys/class/backlight/*; do
        [ -e "$d" ] || continue
        echo "  $(basename "$d")  max=$(cat "$d/max_brightness" 2>/dev/null) cur=$(cat "$d/brightness" 2>/dev/null) : $(readlink -f "$d" 2>/dev/null)"
    done
    echo "=== sound cards ==="
    cat /proc/asound/cards 2>/dev/null || echo "  (none)"

echo "=== kernel log follows ==="
} > "$OUT"

# Follow the kernel log if we are allowed to, and do not spin if we are not.
#
# Neither route works from the shell domain on a stock kernel. `dmesg -w` reads
# the ring buffer via syslog(2), which wants CAP_SYS_ADMIN/CAP_SYSLOG; reading
# /dev/kmsg directly wants CAP_SYSLOG too, because kernel.dmesg_restrict gates
# it regardless of the node being root:log and shell being in that group. And
# shell is an appdomain, which app_neverallows.te forbids any capability at all.
#
# Running as root instead is not a way out: root in the shell domain needs
# CAP_DAC_OVERRIDE for its usual bypass, which is refused the same way.
#
# So take it if it is there, and otherwise exit cleanly. Exiting non-zero made
# init restart the service forever -- 33 times in one boot -- which is noise
# that buries the real log. The header above is the useful part on a device
# with no serial console anyway; the kernel log itself is on ttyS0 and hvc0.
if cat /dev/kmsg >> "$OUT" 2>/dev/null; then
    :
else
    echo "=== /dev/kmsg unreadable (dmesg_restrict, needs CAP_SYSLOG) ===" >> "$OUT"
    echo "=== see ttyS0 or hvc0 for the kernel log ===" >> "$OUT"
fi
exit 0
