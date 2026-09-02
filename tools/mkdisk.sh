#!/usr/bin/env bash
#
# Assemble a bootable GPT disk image for the pc_x86_64 target.
#
#   UEFI (OVMF) -> GRUB on the ESP -> bzImage + ramdisk.img -> Android init
#
# Deliberately rootless: no loop devices, no mounts, no sudo. mtools populates
# the FAT ESP in place and partition images are dd'd to computed GPT offsets.
# That keeps the edit/build/boot loop unprivileged and scriptable.
#
# See doc/06-boot-and-storage.md.
#
set -euo pipefail

X86_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_SRC="$X86_ROOT/linux"
AOSP_ROOT="$X86_ROOT/android_17"
PRODUCT_OUT="$AOSP_ROOT/out/target/product/pc_x86_64"
HOST_BIN="$AOSP_ROOT/out/host/linux-x86/bin"
WORK="$X86_ROOT/out/disk"
DISK="$X86_ROOT/android-pc.img"

# Sized to fit a nominal 16 GB USB stick, which is really ~14.9 GiB. A 32 GiB
# image does not fit a "32GB" stick either (~29.8 GiB usable), so a round
# power-of-two image is exactly the wrong choice for removable media.
# Raise it for a larger target: DISK_SIZE_MB=28672 ./build.sh image
DISK_SIZE_MB=${DISK_SIZE_MB:-14336}
ESP_MB=${ESP_MB:-512}
SYSTEM_MB=${SYSTEM_MB:-6144}
VENDOR_MB=${VENDOR_MB:-2048}
# /metadata holds aconfig flag storage, apex data and encryption metadata.
# Without it aconfigd cannot initialise and every feature flag lookup fails
# with ERROR_PACKAGE_NOT_FOUND, which crash-loops system_server:
#     aconfigd_system: failed to copy /system/etc/aconfig/package.map
#                      to /metadata/aconfig/...
#     selinux: Could not stat /metadata: No such file or directory
#     IllegalArgumentException: Invalid feature flag: android.security.*
METADATA_MB=${METADATA_MB:-64}

# Deterministic PARTUUID for the ESP.
#
# Android init only creates /dev/block/by-name/* symlinks for partitions on the
# *boot device* (devices.cpp:568, `if (info.is_boot_device)`). It learns which
# device that is from androidboot.boot_part_uuid: the PARTUUID of the partition
# holding the kernel, which for us is the ESP. init finds that partition and
# sets boot_devices to the block device containing it.
#
# The older androidboot.boot_devices= takes a sysfs path instead, which would
# hardcode QEMU's virtio-blk topology and break on real NVMe/AHCI hardware.
# The UUID approach is topology-independent, so it works in both.
ESP_PARTUUID=${ESP_PARTUUID:-9d4ae3f2-1e6b-4a58-8b3c-000000000001}

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else R=''; G=''; Y=''; B=''; N=''; fi
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

for t in sgdisk mformat mcopy mmd grub-mkstandalone mke2fs truncate dd; do
    command -v "$t" >/dev/null || die "missing tool: $t  (apt install gdisk mtools grub-efi-amd64-bin e2fsprogs)"
done

mkdir -p "$WORK"

# ---------------------------------------------------------------- inputs ----
BZIMAGE="$KERNEL_SRC/arch/x86/boot/bzImage"
[[ -f "$BZIMAGE" ]] || die "no kernel: $BZIMAGE  (run ./build.sh kernel)"

RAMDISK="$PRODUCT_OUT/ramdisk.img"
SYSTEM_IMG="$PRODUCT_OUT/system.img"
VENDOR_IMG="$PRODUCT_OUT/vendor.img"

missing=()
[[ -f "$RAMDISK"    ]] || missing+=("ramdisk.img")
[[ -f "$SYSTEM_IMG" ]] || missing+=("system.img")
[[ -f "$VENDOR_IMG" ]] || missing+=("vendor.img")
if (( ${#missing[@]} )); then
    die "missing AOSP images in $PRODUCT_OUT: ${missing[*]}
     run:  ANDROID_TARGET=pc_x86_64-trunk_staging-userdebug ./build.sh android"
fi

# AOSP ships ext4 images in Android sparse format; convert if needed.
unsparse() {
    local src=$1 dst=$2 simg2img
    simg2img=$(command -v simg2img || echo "$HOST_BIN/simg2img")
    if head -c4 "$src" | od -An -tx1 | grep -qi '3a ff 26 ed'; then
        [[ -x "$simg2img" ]] || die "sparse image but no simg2img (apt install android-sdk-libsparse-utils)"
        "$simg2img" "$src" "$dst"
    else
        cp --reflink=auto "$src" "$dst"
    fi
}

# ------------------------------------------------------------------ GRUB ----
info "building standalone GRUB EFI image"
# GRUB_DEFAULT=1 selects the verbose entry; KERNEL_EXTRA_ARGS appends to both.
#
# GRUB_TIMEOUT is 5 rather than 3 because the menu is not decoration: the
# install entry is the last one, and three seconds is not enough time to read
# three entries and arrow down to it before the default boots.
cat > "$WORK/grub.cfg" <<EOF
set timeout=${GRUB_TIMEOUT:-5}
set default=${GRUB_DEFAULT:-0}

# The ESP carries a volume label so GRUB finds it regardless of disk ordering.
search --no-floppy --label ANDROIDESP --set=root

# Default entry keeps the kernel console quiet.
#
# ttyS0 is an emulated 16550: every byte is a port write and therefore a VM
# exit. At loglevel=7 a permissive-mode boot emits thousands of avc denials
# (enough to hit "audit: backlog limit exceeded"), and pushing all of that
# through the UART starves the guest badly enough to trip Android's watchdog:
#     Watchdog: *** WATCHDOG KILLING SYSTEM PROCESS:
#               Blocked in handler on main thread (main) for 67s
# with no actual deadlock -- the main thread stack shows ordinary
# ULocale/Configuration/Resources work.
#
# sysctl.kernel.dmesg_restrict=0 makes the kernel log readable without
# CAP_SYSLOG, which is the only way to see it on this device: shell is an
# appdomain and may hold no capability, the machine has no serial header, and
# /proc/sys/kernel/dmesg_restrict is proc_security, which domain.te lets only
# init and vendor_init even READ. Setting it from the command line happens
# before init starts, so no policy is involved at all -- the kernel parses
# sysctl.* itself (fs/proc/proc_sysctl.c, process_sysctl_arg).
#
# This is a bring-up decision with a real cost: kernel addresses and hardware
# detail become readable by any app. Drop it before anything ships.
#
# loglevel=4 keeps warnings and above on the console; everything else is still
# in the ring buffer via dmesg. Logcat comes over virtio-console regardless,
# which is cheap. Use the verbose entry (GRUB_DEFAULT=1) when debugging early
# boot, accepting that it distorts timing.
# video= pins the QEMU display mode, and without it the guest sits at 640x480.
#
# virtio-gpu is told a preferred resolution by -device virtio-vga-gl,xres=,yres=
# and advertises it over EDID -- the guest confirms it negotiated the feature,
# "[drm] features: +virgl +edid" -- and then nothing applies it. fbcon comes up
# at "colour frame buffer device 80x30", which is 640x480, and the scanout stays
# there: measured with xwininfo, the QEMU window was 640x507 ten minutes into a
# boot while the device had been asked for 1824x1024. Android renders into
# whatever mode is set, so the boot animation and the whole UI were 640x480 and
# the window was small because the guest was small.
#
# Setting it here happens before any of that, and drm_hwcomposer inherits the
# mode rather than choosing one.
#
# Virtual-1 is the connector name for virtio-gpu: virtgpu_display.c registers
# DRM_MODE_CONNECTOR_VIRTUAL and drm_connector.c names that type "Virtual".
# Naming the connector rather than using the bare video=WxH form is what keeps
# this out of the way on real hardware, where the panel is eDP-1 and this
# argument matches nothing and is ignored.
#
# GUEST_MODE overrides it at image build time. 1600x900 is the default because
# it fits inside a 1080p host with room for a titlebar, and at density 240 it is
# 1066x600dp, so still a large-screen layout rather than a phone one.
menuentry "Android pc_x86_64" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=enforcing \\
           sysctl.kernel.dmesg_restrict=0 \\
           video=Virtual-1:${GUEST_MODE:-1600x900} \\
           console=ttyS0,115200 loglevel=7
    initrd /ramdisk.img
}

# The verbose entry stays PERMISSIVE on purpose. It is the escape hatch: if a
# policy change makes the default entry unbootable, pick this one at the GRUB
# menu and the denials are logged instead of enforced, which is the only way to
# see what the new policy actually broke.
menuentry "Android pc_x86_64 (verbose, serial only)" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=permissive \\
           sysctl.kernel.dmesg_restrict=0 \\
           console=ttyS0,115200 \\
           loglevel=8 ignore_loglevel printk.devkmsg=on \\
           androidboot.logcat_serial=1 \\
           androidboot.verifiedbootstate=orange ${KERNEL_EXTRA_ARGS:-}
    initrd /ramdisk.img
}
# The installer entry. Copies this image onto the machine's internal disk and
# gives userdata whatever is left of it -- see pc_install.sh, which is what
# androidboot.pc_install=1 starts.
#
# Nothing here erases anything. The flag only makes an init service run instead
# of staying dormant, and that service prints what it is about to destroy and
# waits for the word ERASE. Booting either entry above can never reach it.
#
# console=tty0 is added so the installer is visible on the laptop's own screen.
# The normal entries send the console to serial only, which is right for a
# system with a UI and useless for a text installer on a machine that may have
# no serial cable attached.
#
# androidboot.pc_install_target=<name> can be appended by hand at the GRUB
# prompt on a machine with more than one internal disk; the installer refuses
# to guess between them.
#
# PERMISSIVE, and only here. The installer writes raw block devices, runs
# sgdisk and mke2fs and mounts a FAT filesystem, which under enforcing policy
# would need a domain holding permissions nothing else on the device should
# have. Confining the installer properly means adding those permissions to the
# shipped policy, where they would then exist on every installed system for the
# sake of a program that runs once from removable media. Scoping it to this
# entry keeps the installed system enforcing, which is what the other two
# entries do and what actually matters.
# loglevel=1, far quieter than the other entries, and for the same reason the
# console order is flipped: this screen is a user interface, not a log.
#
# Stopping surfaceflinger and zygote is what keeps the framebuffer console
# visible, but it also means system_server never registers the 'activity'
# service, so servicemanager retries it -- and SurfaceFlingerAIDL -- as lazy
# services once a second, forever:
#     init: Control message: Could not find 'aidl/activity' for ctl.interface_start
# Those go through printk, so at loglevel=4 they land on tty0 and scroll the
# installer's prompt off the screen about as fast as it is drawn.
#
# The two streams filter differently, which is what makes this work: printk
# output obeys the console loglevel, while a write to /dev/console from a
# program's stdout does not. So loglevel=1 silences init and the kernel while
# leaving every line the installer prints exactly where the user can read it.
# The kernel log is still complete in the ring buffer and in the transcript.
#
# CONSOLE ORDER IS LOAD-BEARING, and it is the opposite of the other two
# entries. Linux points /dev/console at the LAST console= on the command line,
# and init gives a service marked `console` that device for its stdin and
# stdout. With tty0 first and ttyS0 last -- the order every other entry uses,
# because for them serial is the debugging channel -- the installer's banner and
# its "Type ERASE to continue" prompt go out the serial port, and a user looking
# at the machine's own screen sees an ordinary boot while the installer blocks
# forever on input that is never coming. This entry is interactive, on the
# machine's own display, so tty0 goes last. Serial still gets the kernel log.
menuentry "Install Android to internal disk (ERASES IT)" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=permissive \\
           androidboot.pc_install=1 \\
           sysctl.kernel.dmesg_restrict=0 \\
           video=Virtual-1:${GUEST_MODE:-1600x900} \\
           console=ttyS0,115200 console=tty0 loglevel=1
    initrd /ramdisk.img
}

# The same install, confirmed HERE instead of at a prompt.
#
# The interactive entry above asks the user to type ERASE on the machine's own
# console. That assumes the kernel's VT layer delivers keystrokes to
# /dev/console, and on this hardware it does not: the kernel has CONFIG_VT,
# VT_CONSOLE, ATKBD, USB_HID and EVDEV all enabled, the prompt appears, and
# nothing typed reaches the reader. Android drives input through evdev and
# InputFlinger, not the VT, so a console prompt is not a reliable way to ask
# this machine's owner a question.
#
# GRUB's own input demonstrably works -- selecting this entry at all requires
# arrowing down to it and pressing enter -- so the confirmation is moved to
# where the keyboard is known to function. androidboot.pc_install_confirm=ERASE
# carries that answer to the installer, which then skips the prompt.
#
# This is a deliberate, clearly labelled, last-in-the-list choice, which is the
# same standard the typed word was there to meet: nothing here can be reached by
# accident, and the default entry is still a normal boot.
menuentry "Install Android to internal disk -- NO PROMPT, ERASES IT NOW" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=permissive \\
           androidboot.pc_install=1 \\
           androidboot.pc_install_confirm=ERASE \\
           sysctl.kernel.dmesg_restrict=0 \\
           video=Virtual-1:${GUEST_MODE:-1600x900} \\
           console=ttyS0,115200 console=tty0 loglevel=1
    initrd /ramdisk.img
}

EOF

# What gets embedded is a loader, not the menu.
#
# grub-mkstandalone bakes its config into the EFI binary, so a menu embedded
# here is unreachable to anything that is not rebuilding the image -- and
# pc_install.sh has to edit the menu: the installed system needs its own
# boot_part_uuid, and it must not keep offering to install itself over its own
# disk. It was written to sed an ESP grub.cfg that this script never actually
# wrote, so the install died on "no grub.cfg on the copied ESP".
#
# So embed six lines that find the ESP by label and hand control to the real
# grub.cfg sitting on it, and ship the menu as a plain file. That also means the
# kernel command line can be edited on a written stick without a rebuild.
cat > "$WORK/grub-embed.cfg" <<'EOFEMBED'
search --no-floppy --label ANDROIDESP --set=root
if [ -f ($root)/grub.cfg ]; then
    configfile ($root)/grub.cfg
else
    echo "ANDROIDESP has no grub.cfg -- cannot boot."
    sleep 30
fi
EOFEMBED

grub-mkstandalone -O x86_64-efi -o "$WORK/bootx64.efi" \
    --modules="part_gpt fat ext2 normal linux echo all_video test true sleep search search_label configfile gzio" \
    "boot/grub/grub.cfg=$WORK/grub-embed.cfg" 2>/dev/null
ok "bootx64.efi $(du -h "$WORK/bootx64.efi" | cut -f1) (loader; menu is grub.cfg on the ESP)"

# ------------------------------------------------------------------- ESP ----
info "building ESP (FAT32, ${ESP_MB} MiB)"
rm -f "$WORK/esp.img"
truncate -s "${ESP_MB}M" "$WORK/esp.img"
mformat -i "$WORK/esp.img" -F -v ANDROIDESP ::
mmd    -i "$WORK/esp.img" ::/EFI ::/EFI/BOOT
mcopy  -i "$WORK/esp.img" "$WORK/bootx64.efi" ::/EFI/BOOT/BOOTX64.EFI
mcopy  -i "$WORK/esp.img" "$BZIMAGE"          ::/bzImage
mcopy  -i "$WORK/esp.img" "$RAMDISK"          ::/ramdisk.img
mcopy  -i "$WORK/esp.img" "$WORK/grub.cfg"    ::/grub.cfg
ok "ESP populated: BOOTX64.EFI, grub.cfg, bzImage, ramdisk.img"

# ------------------------------------------------------- partition images ----
info "preparing partition images"
unsparse "$SYSTEM_IMG" "$WORK/system.raw"
unsparse "$VENDOR_IMG" "$WORK/vendor.raw"
ok "system $(du -h "$WORK/system.raw" | cut -f1), vendor $(du -h "$WORK/vendor.raw" | cut -f1)"

rm -f "$WORK/metadata.raw"
truncate -s "${METADATA_MB}M" "$WORK/metadata.raw"
mke2fs -q -t ext4 -L metadata "$WORK/metadata.raw" >/dev/null 2>&1
ok "metadata ${METADATA_MB} MiB (empty ext4)"

USERDATA_MB=$(( DISK_SIZE_MB - ESP_MB - SYSTEM_MB - VENDOR_MB - METADATA_MB - 16 ))
rm -f "$WORK/userdata.raw"
truncate -s "${USERDATA_MB}M" "$WORK/userdata.raw"
mke2fs -q -t ext4 -L userdata "$WORK/userdata.raw" >/dev/null 2>&1
ok "userdata ${USERDATA_MB} MiB (empty ext4)"

# ------------------------------------------------------------------ disk ----
# Partition NAMES here are what become /dev/block/by-name/* via the kernel's
# EFI partition support -- they must match fstab.pc_x86_64.
info "creating GPT disk ${DISK_SIZE_MB} MiB"
rm -f "$DISK"
truncate -s "${DISK_SIZE_MB}M" "$DISK"

sgdisk -Z "$DISK" >/dev/null 2>&1 || true
sgdisk \
    -n 1:1MiB:+${ESP_MB}MiB    -t 1:ef00 -c 1:esp \
    -n 2:0:+${SYSTEM_MB}MiB    -t 2:8300 -c 2:system \
    -n 3:0:+${VENDOR_MB}MiB    -t 3:8300 -c 3:vendor \
    -n 4:0:+${METADATA_MB}MiB  -t 4:8300 -c 4:metadata \
    -n 5:0:0                   -t 5:8300 -c 5:userdata \
    -u 1:"$ESP_PARTUUID" \
    "$DISK" >/dev/null
ok "esp PARTUUID $ESP_PARTUUID (androidboot.boot_part_uuid)"

# Write each partition image at its GPT-assigned offset.
write_part() {
    local num=$1 src=$2 name=$3 start
    start=$(sgdisk -i "$num" "$DISK" | awk '/First sector/{print $3}')
    [[ -n "$start" ]] || die "could not read start sector of partition $num"
    dd if="$src" of="$DISK" bs=512 seek="$start" conv=notrunc,sparse status=none
    ok "$(printf '%-9s' "$name") -> sector $start"
}

info "writing partitions"
write_part 1 "$WORK/esp.img"      esp
write_part 2 "$WORK/system.raw"   system
write_part 3 "$WORK/vendor.raw"   vendor
write_part 4 "$WORK/metadata.raw" metadata
write_part 5 "$WORK/userdata.raw" userdata

echo
sgdisk -p "$DISK" | tail -6
echo
ok "disk ready: $DISK ($(du -h --apparent-size "$DISK" | cut -f1) apparent, $(du -h "$DISK" | cut -f1) on disk)"
echo "    boot it with:  ./build.sh run"
