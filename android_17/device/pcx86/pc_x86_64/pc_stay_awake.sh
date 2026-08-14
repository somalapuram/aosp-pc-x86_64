#!/system/bin/sh
#
# Stop the machine putting itself to sleep during bring-up.
#
# Android assumes a battery-powered device with a user touching it. This is a
# desktop with, usually, nobody at the keyboard, so PowerManagerService blanks
# the display within seconds of the UI appearing and the kernel then suspends:
#
#     PowerManagerService: Going to sleep due to timeout
#                          (screenOffTimeout=60000, activityTimeoutWM=10000)
#     SurfaceFlinger: Setting power mode 0 on physical display   <- display off
#     ...
#     PM: suspend entry (deep)
#     Freezing user space processes
#
# What that looks like from the front is the boot animation playing, the UI
# appearing for a moment, and then a black screen that never comes back --
# indistinguishable from the display stack having failed, which is exactly how
# it was first reported. Input devices are enumerated (keyboard, tablet, mouse),
# so moving the mouse wakes it; leave it alone and it stays dark.
#
# Two separate things have to be prevented:
#
#   the screen blanking   settings, below -- SurfaceFlinger power mode 0
#   the box suspending    /sys/power/wake_lock -- PM: suspend entry
#
# The first is what makes the display disappear; the second makes the VM stop
# responding altogether.
#
# This is bring-up behaviour, not a considered power policy. A shipping build
# wants a real screen timeout via a SettingsProvider overlay
# (def_screen_off_timeout) rather than a script poking `settings`.

TAG=pc-stay-awake

# Nothing here works until system_server has published the settings provider,
# and this service starts long before that. Retry rather than guess a delay.
i=0
while [ "$i" -lt 60 ]; do
    if settings get system screen_off_timeout >/dev/null 2>&1; then
        break
    fi
    i=$((i + 1))
    sleep 5
done

if [ "$i" -ge 60 ]; then
    log -t "$TAG" "settings provider never came up; giving up"
else
    # Maximum int: the largest value the framework accepts.
    settings put system screen_off_timeout 2147483647
    # -1 disables the separate "sleep" (doze) timeout.
    settings put secure sleep_timeout -1
    # Stay on for AC, USB and wireless charging. Harmless where there is no
    # battery at all, which is the case on a desktop -- healthd reports
    # "battery none" -- but correct on a laptop running this image.
    settings put global stay_on_while_plugged_in 7
    log -t "$TAG" "screen_off_timeout=$(settings get system screen_off_timeout) sleep_timeout=$(settings get secure sleep_timeout)"
fi

# Belt and braces: a kernel wakelock blocks deep suspend regardless of what
# the framework decides. Without this the box can still drop into S3 and stop
# responding to everything except a power button.
if echo "$TAG" > /sys/power/wake_lock 2>/dev/null; then
    log -t "$TAG" "holding kernel wakelock"
else
    log -t "$TAG" "could not take a kernel wakelock (CONFIG_PM_WAKELOCKS?)"
fi
