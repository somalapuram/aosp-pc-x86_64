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

# --------------------------------------------------------- GPU firmware ----
# NVIDIA GSP ships in a SECOND INITRAMFS, not in the kernel.
#
# This is what finally makes nouveau possible here, and it is the answer
# doc/08-roadmap.md predicted. CONFIG_EXTRA_FIRMWARE is how i915 and amdgpu are
# served, and it cannot work for NVIDIA: one Ada GSP blob is 61 MB against a
# 24 MB bzImage, and every additional GPU family would add tens of megabytes to
# a kernel that has to be loaded whole on every machine.
#
# Firmware in an initramfs avoids all of that, and it works for a BUILT-IN
# driver, which is the part that is easy to get wrong:
#
#   - init/initramfs.c:792 is rootfs_initcall(populate_rootfs), and the initcall
#     order is fs(5) -> rootfs -> device(6). Built-in drivers probe at
#     device_initcall, so the archive is already unpacked when nouveau probes.
#   - firmware_loader/main.c:513 calls wait_for_initramfs() before searching, so
#     even async unpacking is waited for rather than raced.
#   - main.c:472 lists /lib/firmware among the search paths, and 881/886 accept
#     .zst and .xz. CONFIG_FW_LOADER_COMPRESS_ZSTD is on, so the blobs ship
#     exactly as linux-firmware stores them -- compressed, 202 MB of nvidia
#     rather than ~280 MB -- and nothing here has to decompress anything.
#
# GRUB concatenates multiple initrd files into one image, which is how distros
# ship early microcode, so this needs no change on the kernel side at all.
#
# WHY 570.144 AND NOT 535.113.01. gsp/ad102.c lists both, 570.144 FIRST:
#     { 1, tu102_gsp_load, &ad102_gsp, &r570_rm_ga102, "570.144"    },
#     { 0, tu102_gsp_load, &ad102_gsp, &r535_rm_ga102, "535.113.01" },
# so shipping only the smaller 535 set (37 MB) would miss on 570 first, and a
# miss is not free -- see the timeout note below. 61 MB and no stall beats
# 37 MB and a guaranteed one.
#
# THE 60-SECOND TRAP, kept here because it is why this took so long to attempt.
# CONFIG_FW_LOADER_USER_HELPER_FALLBACK=y sets
# fw_fallback_config.force_sysfs_fallback (fallback_table.c:21), so EVERY miss
# takes the sysfs path and blocks for .loading_timeout = 60 seconds
# (fallback_table.c:22) waiting for a userspace helper that does not exist yet.
# nouveau uses firmware_request_nowarn() (nvkm/core/firmware.c:94), which sets
# FW_OPT_UEVENT without FW_OPT_USERHELPER -- exactly the combination that
# fw_force_sysfs_fallback() grants the fallback to. So nouveau misses stall too.
# nouveau is built in and drivers/Makefile runs gpu/ (line 68) before usb/
# (line 107), so it happens before USB is even up: black screen, NumLock dead,
# mouse light off. Three boots were abandoned as "hung" during exactly this.
#
# The consequence for THIS file: a machine whose NVIDIA chip is not in
# NVIDIA_FW_CHIPS below still stalls. Add the family rather than re-deriving it.
# Every GPU family AMD, Intel and NVIDIA ship firmware for, not a chip list.
#
# A per-chip list does not survive contact with real machines: this project has
# already been caught out twice by it, once assuming Ampere when the part was
# Ada (AD107 vs GA10x), and once shipping ad107 to a laptop whose dGPU is a
# GA107. The chip is not guessable from the model name and the failure is a
# 60-second stall per missing file, so the answer is to ship the lot.
#
# It is affordable only because these stay COMPRESSED -- the kernel reads
# firmware/foo.bin.zst directly (see CONFIG_FW_LOADER_COMPRESS_ZSTD). Measured
# from linux-firmware: nvidia 202 MB, amdgpu 27 MB, i915 9.3 MB, so ~238 MB of
# a 512 MB ESP against roughly 345 MB expanded. linux-firmware also symlinks
# heavily -- 274 nvidia files share just 4 distinct GSP blobs -- and cp -a plus
# cpio preserve those, so the archive never carries a blob twice.
GPU_FW_VENDORS="${GPU_FW_VENDORS:-nvidia amdgpu i915}"
GPU_FW_SRC="${GPU_FW_SRC:-/lib/firmware}"

# nvidia/595.84 is 99 MB -- half the nvidia tree -- and nouveau cannot ask for
# it. nvkm/core/firmware.c:90-92 builds every nouveau firmware path as
#     nvidia/<chip>/<name>.bin        e.g. nvidia/ga107/gsp/booter_load-570.144.bin
# where <chip> is a chip codename, so a directory named after a PROPRIETARY
# DRIVER VERSION is unreachable by construction; gsp_ga10x.bin and gsp_tu10x.bin
# appear nowhere in drivers/gpu/drm/nouveau. They belong to NVIDIA's own
# nvidia.ko, which is not in this image.
#
# The reason is disk, and only disk: 99 MB off a 512 MB ESP. It is NOT a boot-time
# fix, and the archive's size turns out not to cost boot time at all -- across six
# boots the initrd ranged 1.5 MB to 238 MB and i915 still probed at 21.7-22.1 s
# every time, because what actually delays the probe is the verbose GRUB entry
# (loglevel=8 ignore_loglevel earlycon=efifb keep_bootcon), which paints every
# printk to the EFI framebuffer at ~35 ms each. Unpacking 238 MB costs 0.2 s.
GPU_FW_EXCLUDE="${GPU_FW_EXCLUDE:-nvidia/595.84}"

# ------------------------------------------------ radio firmware ----
# WiFi and Bluetooth firmware, by the same mechanism and for the same reason.
#
# The AMD workstation came up with no WiFi and no Bluetooth. Half of that was
# the kernel (only CONFIG_IWLWIFI was built -- see config/pc_x86_64.fragment),
# and the other half is here: a driver without its firmware is a driver that
# probes and then fails, which looks identical to a missing driver.
#
# TWO ARMS, because linux-firmware is not consistently laid out and the GPU loop
# above only knows about subdirectories:
#
#   HW_FW_DIRS   subdirectories, copied whole (may be nested, e.g. intel/iwlwifi)
#   HW_FW_GLOBS  FLAT top-level files, which a subdir loop silently copies ZERO of
#
# That second arm is not a nicety. The 180 iwlwifi blobs (76 MB) do NOT live in
# /lib/firmware/iwlwifi/ -- they sit flat at the top level as
# iwlwifi-*.ucode.zst, so a vendor-directory loop would have bundled nothing at
# all for the one WiFi driver this image already had.
# cirrus/ is the speaker amplifier, not a radio. HP laptops drive their speakers
# through Cirrus CS35L41 amps hanging off the HDA codec (an ALC245 on the AMD
# machine), and CONFIG_SND_HDA_SCODEC_CS35L41{,_I2C,_SPI} are already =y -- only
# the blobs were missing, so the amp fell back to a default profile and the
# speakers stayed silent while AudioFlinger reported a perfectly healthy
# AUDIO_DEVICE_OUT_SPEAKER. 2.5 MB.
HW_FW_DIRS="${HW_FW_DIRS:-rtw88 rtw89 rtlwifi mediatek ath10k ath11k ath12k ath9k_htc brcm cypress qca rtl_bt ar3k rtl_nic intel/iwlwifi cirrus}"

# regulatory.db is the cheapest entry here and the easiest to miss. The kernel
# has CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y, and net/wireless/reg.c requests
# "regulatory.db" + "regulatory.db.p7s"; without them cfg80211 falls back to the
# built-in world domain, which makes most 5 GHz channels passive and 6 GHz
# unavailable. The symptom is "wifi connects but is slow, and the 5 GHz SSID is
# missing" -- which reads as a driver bug and is not one. 7.3 KB.
#
# intel/ibt-* is Intel Bluetooth. It is globbed rather than taking all of
# intel/, because that directory is 57 MB of which 26 MB is camera (ipu, vsc),
# audio (sof) and ISH firmware this image has no driver for.
HW_FW_GLOBS="${HW_FW_GLOBS:-regulatory.db regulatory.db.p7s iwlwifi-*.ucode* iwlwifi-*.pnvm* intel/ibt-* htc_9271.fw* htc_7010.fw* ath3k-1.fw* carl9170-1.fw* ar5523.bin*}"

# nouveau.modeset is now passed EXPLICITLY, and defaults to on.
#
# Leaving it out would already enable the driver -- nouveau_modeset defaults to
# -1 (auto) and nouveau_drm.c:1490 only turns that into 0 when
# drm_firmware_drivers_only() is true, i.e. when `nomodeset` is on the command
# line, which this image never passes. Stating it anyway is worth the eight
# characters: the boot log then shows what was asked for rather than what was
# defaulted to, so a boot that does not probe can be told apart from a boot that
# probed and failed without re-deriving the kernel's default.
#
# NOUVEAU_MODESET=0 in the environment puts the old workaround back for a
# machine whose GSP firmware is not in NVIDIA_FW_CHIPS. It is checked before the
# driver registers, so there is no probe and no firmware request at all --
# modprobe.blacklist would NOT work, because nouveau is built in.
NOUVEAU_MODESET="${NOUVEAU_MODESET:-1}"

# nouveau.atomic=1 is REQUIRED, not a tuning knob.
#
# nouveau keeps the atomic ioctl behind a module parameter that defaults OFF:
#     MODULE_PARM_DESC(atomic, "Expose atomic ioctl (default: disabled)");
#     static int nouveau_atomic = 0;                    nouveau_drm.c:106-108
#     if (nouveau_atomic)
#             driver_pci.driver_features |= DRIVER_ATOMIC;   nouveau_drm.c:882
# so without it the driver never advertises DRIVER_ATOMIC and
# drmSetClientCap(DRM_CLIENT_CAP_ATOMIC) fails. drm_hwcomposer is atomic-only,
# so that is fatal rather than a downgrade -- observed on an RTX 2000 Ada
# (AD107) where the kernel side was perfect (GSP 570.144 loaded, 16380 MiB VRAM,
# nouveaudrmfb primary) and userspace still went:
#     E drmhwc: Failed to set atomic cap -1
#     I drmhwc: No pipelines available. Creating null-display for headless mode
#     F SurfaceFlinger: output buffer not gpu writeable   <- abort, 13 times
# The SurfaceFlinger abort is downstream of the null display, not a gralloc bug:
# minigbm's dumb backend does grant BO_USE_RENDER_MASK|BO_USE_SCANOUT for
# ARGB/XRGB8888 (dumb_driver.c:38-39).
#
# The parameter is 0400 -- readable but not writable after boot -- so it has to
# be on the command line; there is no runtime way to set it.
NOUVEAU_ATOMIC="${NOUVEAU_ATOMIC:-1}"
NOUVEAU_ARG="nouveau.modeset=${NOUVEAU_MODESET} nouveau.atomic=${NOUVEAU_ATOMIC}"

# Build the GPU firmware initramfs. See the NVIDIA GSP note above for why the
# firmware is delivered this way rather than linked into the kernel.
#
# The layout inside the archive is the kernel's search path with no leading
# slash -- lib/firmware/nvidia/<chip>/gsp/... -- because a cpio's members are
# relative and populate_rootfs unpacks them at /.
info "building GPU firmware initramfs"
FWROOT="$WORK/fwroot"
rm -rf "$FWROOT"
FW_COUNT=0
mkdir -p "$FWROOT/lib/firmware"
for vendor in $GPU_FW_VENDORS; do
    src="$GPU_FW_SRC/$vendor"
    if [[ ! -d "$src" ]]; then
        warn "no $vendor firmware at $src -- that vendor's GPUs will stall 60s per missing file"
        continue
    fi
    # -a keeps symlinks AS symlinks. linux-firmware leans on them heavily
    # (ad107 -> ad102, and ad102's gsp blob -> ga102's), and dereferencing here
    # would turn 4 shared GSP blobs into a copy per chip.
    cp -a "$src" "$FWROOT/lib/firmware/"

    # Drop what no in-tree driver can ask for. GPU_FW_EXCLUDE holds paths
    # relative to $GPU_FW_SRC; see the note above for why 595.84 is in it.
    for ex in $GPU_FW_EXCLUDE; do
        case "$ex" in "$vendor"/*) ;; *) continue ;; esac
        [[ -e "$FWROOT/lib/firmware/$ex" ]] || continue
        rm -rf "$FWROOT/lib/firmware/$ex"
        ok "$vendor: pruned $ex"
    done

    # Count what was actually STAGED, not what is in $src -- after a prune the
    # source count overstates, and this number is what tells us at a glance
    # whether the archive still holds what the drivers need.
    dst="$FWROOT/lib/firmware/$vendor"
    n=$(find "$dst" -type f | wc -l)
    l=$(find "$dst" -type l | wc -l)
    FW_COUNT=$(( FW_COUNT + n + l ))
    ok "$vendor: $n files + $l links, $(du -sh --apparent-size "$dst" | cut -f1)"
done

# Radio firmware, both arms. Missing pieces are a warning, never fatal: a
# machine with no Realtek card does not care that rtw89/ was absent from the
# build host, and this must not stop an image being built.
for d in $HW_FW_DIRS; do
    src="$GPU_FW_SRC/$d"
    if [[ ! -d "$src" ]]; then
        warn "no firmware dir $d at $src -- that hardware will probe and fail"
        continue
    fi
    mkdir -p "$FWROOT/lib/firmware/$(dirname "$d")"
    cp -a "$src" "$FWROOT/lib/firmware/$(dirname "$d")/"
    dst="$FWROOT/lib/firmware/$d"
    n=$(find "$dst" -type f | wc -l); l=$(find "$dst" -type l | wc -l)
    FW_COUNT=$(( FW_COUNT + n + l ))
    ok "$d: $n files + $l links, $(du -sh --apparent-size "$dst" | cut -f1)"
done

for g in $HW_FW_GLOBS; do
    # Count first: an unmatched glob stays literal, and cp would then fail.
    # shellcheck disable=SC2086
    matches=$(ls -d $GPU_FW_SRC/$g 2>/dev/null | wc -l)
    if (( matches == 0 )); then
        warn "no firmware matching $g -- that hardware will probe and fail"
        continue
    fi
    mkdir -p "$FWROOT/lib/firmware/$(dirname "$g")"
    # shellcheck disable=SC2086
    cp -a $GPU_FW_SRC/$g "$FWROOT/lib/firmware/$(dirname "$g")/"
    FW_COUNT=$(( FW_COUNT + matches ))
    ok "$g: $matches files, $(du -shc --apparent-size $GPU_FW_SRC/$g 2>/dev/null | tail -1 | cut -f1)"
done

if (( FW_COUNT > 0 )); then
    # -H newc is the only format the kernel's initramfs unpacker accepts.
    ( cd "$FWROOT" && find . -print0 | cpio --null -o -H newc --quiet ) > "$WORK/gpufw.img"
    ok "gpufw.img $(du -h "$WORK/gpufw.img" | cut -f1) ($FW_COUNT files)"
    GPUFW_INITRD=" /gpufw.img"
else
    warn "no GPU firmware bundled; nouveau left disabled"
    NOUVEAU_ARG="nouveau.modeset=0"   # atomic is moot with the driver off
    GPUFW_INITRD=""
fi


info "building standalone GRUB EFI image"
# The DEFAULT is entry 0, the quiet one.
#
# It was entry 1, "verbose, on screen", through bring-up. On a machine that had
# never booted this image the quiet entry was worse than useless: it printed
# nothing to the screen AND omitted sysctl.kernel.dmesg_restrict=0, so
# pc_kmsg_file.sh wrote every section of its report except the kernel log --
#
#     === /dev/kmsg unreadable (dmesg_restrict, needs CAP_SYSLOG) ===
#
# -- and a whole boot cycle produced no evidence at all. That happened twice on
# the AMD workstation.
#
# It is no longer the right default. The machines boot, the log capture writes
# reliably from post-fs-data, and loglevel=8 painted through fbcon is slow
# enough to be a nuisance on every ordinary boot. The verbose entries are one
# arrow-key away when something needs reading. Set GRUB_DEFAULT=1 to put the
# visible entry back. KERNEL_EXTRA_ARGS appends to every entry.
#
# GRUB_TIMEOUT is 5 rather than 3 because the menu is not decoration: the
# install entry is the last one, and three seconds is not enough time to read
# the entries and arrow down to it before the default boots.
cat > "$WORK/grub.cfg" <<EOF
# 20 s, not 5. Five seconds auto-boots the default before anyone can read the
# menu, let alone pick a diagnostic entry. That cost four boot cycles on the AMD
# laptop: the "AMD I2C/GPIO ENABLED" entry -- the only way to get speakers or a
# touchpad on that machine -- was never once selected, and every boot came back
# on the default with the drivers still blacklisted, which read as "the fix did
# not work" rather than "the entry was never chosen".
set timeout=${GRUB_TIMEOUT:-20}
set default=${GRUB_DEFAULT:-0}

# The ESP carries a volume label so GRUB finds it regardless of disk ordering.
search --no-floppy --label ANDROIDESP --set=root

# loglevel=1 on every entry that paints the screen.
#
# The kernel keeps writing to tty0 after SurfaceFlinger owns the display, and
# each message repaints part of the framebuffer underneath the compositor. With
# NVIDIA render offload running -- nouveau rendering, i915 scanning out -- that
# showed as constant flicker across the whole desktop, not just a scrolling
# corner. loglevel=7/8 with ignore_loglevel made it continuous.
#
# Nothing is lost by this: pc_kmsg_vendor.sh streams /dev/kmsg to
# /data/vendor/pc/kmsg.txt from post-fs-data regardless of console level, so a
# failed boot still leaves the full kernel log on disk. loglevel only decides
# what gets PAINTED.
#
# The one exception is the NVIDIA display-debug entry, which stays at
# loglevel=8 ignore_loglevel because its entire purpose is to be photographed
# off a screen that is about to die -- quietening it would make it a duplicate
# of the entry above it.
#
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
# sysctl.kernel.dmesg_restrict=0 is NOT on the default entry, and that is the
# whole point of it not being there. It makes the kernel log readable without
# CAP_SYSLOG, which is the only way to see it on this device: shell is an
# appdomain and may hold no capability, the machine has no serial header, and
# /proc/sys/kernel/dmesg_restrict is proc_security, which domain.te lets only
# init and vendor_init even READ. Setting it from the command line happens
# before init starts, so no policy is involved at all -- the kernel parses
# sysctl.* itself (fs/proc/proc_sysctl.c, process_sysctl_arg).
#
# It carries a real cost -- kernel addresses and hardware detail become
# readable by any app -- so it is now confined to the entries where that trade
# is worth making and the exposure is bounded: the verbose entry, which exists
# to be debugged from, and the two install entries, which run once from
# removable media and reboot. A normally booted, installed system does not
# have it. pc_kmsg_file.sh already degrades cleanly when /dev/kmsg is refused,
# writing a note saying so rather than restarting forever.
#
# loglevel=4 keeps warnings and above on the console; everything else is still
# in the ring buffer via dmesg. Logcat comes over virtio-console regardless,
# which is cheap. Use the verbose entry (GRUB_DEFAULT=1) when debugging early
# boot, accepting that it distorts timing.
# The blacklist here is ONE driver, not three, and that is a deliberate bisect
# step rather than a leftover.
#
# Three AMD symbols (PINCTRL_AMD, I2C_AMD_MP2, I2C_DESIGNWARE_PCI) were the only
# kernel change between a build that booted this laptop and one that did not, so
# all three were blacklisted to get a bootable default back. But the machine
# needs them: the CS35L41 speaker amps and the SYNA3115/ELAN2513 touchpad are
# all I2C devices, and with the buses dead there is no sound and no touchpad.
#
# Blacklisting only amd_gpio_driver_init leaves the I2C controllers running and
# disables just pinctrl-amd, which is the one with a known failure mode that
# fits the symptom -- it registers GPIO interrupts after the console is up, and
# a stuck GPIO IRQ wedges the machine at exactly that point.
#
# So this entry is now an experiment that runs itself:
#   boots  -> the I2C drivers are innocent, pinctrl-amd is the culprit, and the
#             speaker amps may bind (the touchpad still will not: its ACPI
#             GpioInt needs pinctrl-amd)
#   hangs  -> pinctrl-amd was not the only problem, and the I2C drivers are
#             implicated too
# Either way the answer arrives without anyone having to pick a menu entry --
# four consecutive boots came back on the default with the full blacklist still
# applied, because the diagnostic entry was never selected.
#
# DO NOT put earlycon=efifb on this entry, however tempting it is when a boot
# looks dead.
#
# earlycon=efifb writes each printk straight into the EFI framebuffer and
# scrolls it by moving the whole buffer through uncached MMIO. This file already
# notes ~35 ms a line on a 1920x1200 panel. On a 2560x1600 one that is 16 MB per
# scroll and it measures at roughly TWO SECONDS PER LINE -- a few hundred early
# messages is ten minutes of a machine that looks hung and is only painting.
# That cost a round trip: a boot was reported as "not booting" when it was
# almost certainly still going.
#
# androidboot.pc_logs=1 is the cheap way to get the same information: the kernel
# ring buffer is dumped to /data/local/tmp/kmsg.txt once Android is up, with no
# console painting at all. Keep this entry quiet and read the disk.
#
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
           video=Virtual-1:${GUEST_MODE:-1600x900} \\
           ${NOUVEAU_ARG} \\
           sysctl.kernel.dmesg_restrict=0 \\
           printk.devkmsg=on \\
           androidboot.pc_logs=1 \\
           initcall_blacklist=amd_gpio_driver_init \\
           console=tty0 loglevel=1 ${KERNEL_EXTRA_ARGS:-}
    initrd /ramdisk.img${GPUFW_INITRD}
}

# The verbose entry stays PERMISSIVE on purpose. It is the escape hatch: if a
# policy change makes the default entry unbootable, pick this one at the GRUB
# menu and the denials are logged instead of enforced, which is the only way to
# see what the new policy actually broke.
# The entry to reach for on a machine you have never booted before.
#
# Every other non-install entry sends the console to ttyS0 and nothing else, so
# on a desktop or laptop with no serial header they are all silent: the screen
# stays black whether the boot succeeded, panicked, or hung, and there is no way
# to tell which. That cost a whole boot cycle on the AMD/NVIDIA workstation,
# where the fix turned out to be hand-editing this line from the GRUB menu.
#
# console=tty0 is LAST on purpose, and it is the same load-bearing ordering the
# installer entries document below: Linux points /dev/console at the last
# console= on the command line, so putting tty0 there gives init's own stdout to
# the screen as well as the kernel's printk.
#
# console=ttyS0 is deliberately ABSENT from this entry and from the default one.
# This machine has no serial port, and the kernel does not know that: every
# printk still gets written byte by byte to the 16550 I/O ports, each write
# spinning on a transmitter-empty bit that never sets. At loglevel=8 with
# ignore_loglevel that is thousands of messages, and the boot visibly crawls --
# the user's words were "very slow in log printing". The UART cost is paid even
# though nothing is attached to read it. The "serial only" entry below keeps
# ttyS0 for anyone who does have a cable.
#
# earlycon=efifb is not decoration and it is not redundant with console=tty0.
# tty0 does not exist until a DRM driver binds and DRM_FBDEV_EMULATION builds
# fbcon on top of it, so if the kernel dies before or during GPU probe -- which
# is precisely when you most need to see it -- console=tty0 prints nothing at
# all. earlycon writes to the UEFI framebuffer immediately, and keep_bootcon
# stops it being torn down the moment the real console registers, so the two
# overlap rather than leaving a blind window between them.
#
# Append initcall_debug by hand when hunting a hang: the last line printed then
# names the driver that never returned.
menuentry "Android pc_x86_64 (verbose, on screen)" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=permissive \\
           initcall_blacklist=amd_gpio_driver_init \\
           sysctl.kernel.dmesg_restrict=0 \\
           loglevel=1 printk.devkmsg=on \\
           androidboot.logcat_serial=1 \\
           androidboot.pc_logs=1 \\
           androidboot.verifiedbootstate=orange \\
           ${NOUVEAU_ARG} \\
           earlycon=efifb keep_bootcon \\
           console=tty0 ${KERNEL_EXTRA_ARGS:-}
    initrd /ramdisk.img${GPUFW_INITRD}
}

# The same verbose on-screen boot with NVIDIA switched off, as a menu entry
# rather than something to hand-edit at the GRUB prompt.
#
# It exists because editing the linux line by hand is unreliable: these entries
# are wrapped across continuation lines, and an append that lands in the wrong
# place is silently dropped -- a boot meant to test nouveau.modeset=0 came back
# with nouveau.modeset=1 still on the command line and nouveau bound.
#
# It is also the recovery path on any machine where the NVIDIA GPU misbehaves,
# and the A/B half of "is the second DRM device the problem?" -- boot this and
# the entry above, and the only difference is whether nouveau is present.
# For the case where NVIDIA owns the display and the boot dies before /data.
#
# That failure leaves NO evidence at all: no font change, blank screen, /data
# never mounted, so pc_kmsg_vendor.sh never runs and there is nothing on disk to
# read afterwards. The only channel left is the screen itself, before whatever
# takes the display blanks it -- so this entry is built to make that last
# screenful name the culprit.
#
#   initcall_debug     prints every driver init as it starts AND returns, so the
#                      last unpaired line is the one that never came back
#   nouveau.debug=...  nouveau's own probe/GSP/modeset chatter
#   drm.debug=0x1e     DRM core: driver, KMS, atomic, and lease messages
#   keep_bootcon       earlycon is NOT torn down when the real console
#                      registers, which is the window this failure lives in
#
# Photograph the last few lines. Expect it to be verbose and slow -- that is the
# point; this entry exists to be read off a screen, not to be lived in.
menuentry "Android pc_x86_64 (NVIDIA display debug)" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=permissive \\
           initcall_blacklist=amd_gpio_driver_init \\
           sysctl.kernel.dmesg_restrict=0 \\
           loglevel=8 ignore_loglevel printk.devkmsg=on \\
           androidboot.pc_logs=1 \\
           androidboot.verifiedbootstate=orange \\
           nouveau.modeset=1 nouveau.atomic=1 \\
           nouveau.debug=info,fb=debug,gsp=debug,disp=debug \\
           drm.debug=0x1e initcall_debug \\
           earlycon=efifb keep_bootcon \\
           console=tty0 ${KERNEL_EXTRA_ARGS:-}
    initrd /ramdisk.img${GPUFW_INITRD}
}

# Render on the NVIDIA GPU, scan out on the one wired to the panel.
#
# On a muxless laptop the discrete GPU has no connectors at all, so it can never
# be the display -- but it can still be the RENDERER, with the iGPU scanning out
# what it draws. That is PRIME render offload, and this entry is what asks for it:
# androidboot.pc_render_gpu=offload becomes ro.boot.pc_render_gpu, which
# pc_select_egl.sh reads before it publishes drm.gpu.vendor_name.
#
# Nothing in the image is per-board. The script discovers the offload GPU by the
# only property that matters -- a card with a render node and NO CONNECTORS AT
# ALL -- so this entry does the right thing on any machine, and does nothing at
# all on one with a single GPU.
#
# "No connected connector" was the test until it blanked the AMD workstation:
# there the iGPU has four outputs with nothing plugged into them, which made it
# look like an offload card, so Android rendered on the iGPU and asked the 3070
# Ti to scan out a foreign buffer. A muxless dGPU has no connectors to begin
# with -- see pc_select_egl.sh for the post-mortem.
#
# Why this is a MENU ENTRY and not the default:
#
# droid_open_device() in Mesa does not fall back once drm.gpu.vendor_name is set.
# It filters to the matching card, tries it, and breaks out of the loop whether
# or not the screen was created:
#     if (!droid_probe_device(disp, false)) { close(fd); fd = -1; }
#     break;
# So if nouveau cannot make a screen on this particular chip, EGL initialisation
# fails, SurfaceFlinger cannot find a GL implementation, and it aborts in a loop
# -- a black screen and no way in. The default entry keeps rendering on the card
# that is known to work; picking this one is a deliberate act, and picking the
# default again at the menu is the whole of the way back.
#
# PERMISSIVE and on-screen because this is a bring-up entry: if it fails, the
# reason needs to be readable off the panel, and a policy denial must not be
# what stops it before Mesa has even been asked the question.
# A bootable fallback for the AMD I2C/GPIO drivers, so bisecting them costs a
# reboot instead of a rebuild.
#
# PINCTRL_AMD, I2C_AMD_MP2 and I2C_DESIGNWARE_PCI were added to make an AMD
# laptop touchpad enumerate (its interrupt is an ACPI GpioInt through the AMD
# GPIO controller, so without pinctrl-amd i2c_hid_acpi never probes). Adding
# them was also the only kernel change between a build that booted that laptop
# and one that hung with a black screen right after the GRUB menu.
#
# initcall_blacklist works on BUILT-IN drivers, which modprobe.blacklist cannot
# touch -- everything in this image is =y, there is no /lib/modules and no
# modprobe. The three names are the initcall symbols verified with nm(1) against
# the built vmlinux, not guessed:
#     amd_gpio_driver_init       pinctrl-amd
#     amd_mp2_pci_driver_init    i2c-amd-mp2-pci
#     dw_i2c_driver_init         i2c-designware-platform
# A name that does not exist is silently ignored, which is exactly how a
# blacklist entry can look like it worked and do nothing -- hence nm.
#
# This entry also turns logging on, because the default entry does NOT set
# androidboot.pc_logs=1 and therefore writes no logs at all even on a healthy
# boot. That cost one diagnostic cycle: an empty /data/local/tmp was read as
# "died before Android started" when it only meant "logging was never enabled".
# Boot with the firmware initramfs LEFT OUT entirely.
#
# This is the one test that separates "the kernel hangs on a driver" from "the
# boot never gets that far", and it costs a menu selection rather than a build.
# gpufw.img is 326 MiB and GRUB has to allocate and load all of it before the
# kernel runs; if the machine dies with NO console output at all -- not even
# earlycon=efifb, which prints long before any of the I2C or GPIO drivers probe
# -- then whatever is wrong happens before driver init, and the firmware archive
# is the largest thing in that path.
#
# The cost of choosing this entry is real but bounded: without /lib/firmware,
# amdgpu gets no Phoenix microcode and will likely fall back to a bare
# framebuffer or fail to bind, and WiFi will not come up. That is fine for a
# diagnostic -- the question is only whether it REACHES userspace.
menuentry "Android pc_x86_64 (no firmware initrd, verbose)" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=permissive \\
           initcall_blacklist=amd_gpio_driver_init \\
           sysctl.kernel.dmesg_restrict=0 \\
           loglevel=7 printk.devkmsg=on \\
           androidboot.logcat_serial=1 \\
           androidboot.pc_logs=1 \\
           androidboot.verifiedbootstate=orange \\
           nouveau.modeset=0 \\
           earlycon=efifb keep_bootcon \\
           console=tty0 ${KERNEL_EXTRA_ARGS:-}
    initrd /ramdisk.img
}

menuentry "Android pc_x86_64 (ENABLE pinctrl-amd: touchpad+speakers, MAY HANG)" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=permissive \\
           sysctl.kernel.dmesg_restrict=0 \\
           printk.devkmsg=on \\
           androidboot.pc_logs=1 \\
           androidboot.verifiedbootstate=orange \\
           ${NOUVEAU_ARG} \\
           console=tty0 loglevel=1 ${KERNEL_EXTRA_ARGS:-}
    initrd /ramdisk.img${GPUFW_INITRD}
}
}

menuentry "Android pc_x86_64 (NVIDIA render offload)" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=permissive \\
           initcall_blacklist=amd_gpio_driver_init \\
           androidboot.pc_render_gpu=offload \\
           androidboot.vulkan_hal=nouveau \\
           sysctl.kernel.dmesg_restrict=0 \\
           loglevel=1 printk.devkmsg=on \\
           androidboot.logcat_serial=1 \\
           androidboot.pc_logs=1 \\
           androidboot.verifiedbootstate=orange \\
           ${NOUVEAU_ARG} \\
           earlycon=efifb keep_bootcon \\
           console=tty0 ${KERNEL_EXTRA_ARGS:-}
    initrd /ramdisk.img${GPUFW_INITRD}
}

menuentry "Android pc_x86_64 (verbose, on screen, NVIDIA disabled)" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=permissive \\
           initcall_blacklist=amd_gpio_driver_init \\
           sysctl.kernel.dmesg_restrict=0 \\
           loglevel=1 printk.devkmsg=on \\
           androidboot.logcat_serial=1 \\
           androidboot.pc_logs=1 \\
           androidboot.verifiedbootstate=orange \\
           nouveau.modeset=0 \\
           earlycon=efifb keep_bootcon \\
           console=tty0 ${KERNEL_EXTRA_ARGS:-}
    initrd /ramdisk.img${GPUFW_INITRD}
}

menuentry "Android pc_x86_64 (verbose, serial only)" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=permissive \\
           initcall_blacklist=amd_gpio_driver_init \\
           sysctl.kernel.dmesg_restrict=0 \\
           ${NOUVEAU_ARG} \\
           console=ttyS0,115200 \\
           loglevel=1 printk.devkmsg=on \\
           androidboot.logcat_serial=1 \\
           androidboot.pc_logs=1 \\
           androidboot.verifiedbootstate=orange ${KERNEL_EXTRA_ARGS:-}
    initrd /ramdisk.img${GPUFW_INITRD}
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
# and init gives a service marked 'console' that device for its stdin and
# stdout. With tty0 first and ttyS0 last -- the order every other entry uses,
# because for them serial is the debugging channel -- the installer's banner and
# its "Type ERASE to continue" prompt go out the serial port, and a user looking
# at the machine's own screen sees an ordinary boot while the installer blocks
# forever on input that is never coming. This entry is interactive, on the
# machine's own display, so tty0 goes last. Serial still gets the kernel log.
# loglevel=4, NOT 1 and not 7. pc_install.sh writes progress to /dev/kmsg at <3>
# (KERN_ERR) precisely so it is visible, but printk only prints levels BELOW the
# console loglevel -- at loglevel=1 nothing below level 1 shows, so every
# installer line went into the ring buffer and the screen stayed blank while the
# install ran. The script's own header assumes loglevel=4; give it 7 so both the
# kmsg lines and any driver messages during the copy are on screen.
menuentry "Install Android to internal disk (ERASES IT)" {
    linux  /bzImage root=/dev/ram0 rw \\
           androidboot.hardware=pc_x86_64 \\
           androidboot.boot_part_uuid=$ESP_PARTUUID \\
           androidboot.selinux=permissive \\
           initcall_blacklist=amd_gpio_driver_init \\
           androidboot.pc_install=1 \\
           sysctl.kernel.dmesg_restrict=0 \\
           video=Virtual-1:${GUEST_MODE:-1600x900} \\
           ${NOUVEAU_ARG} \\
           console=ttyS0,115200 console=tty0 loglevel=4 ${KERNEL_EXTRA_ARGS:-}
    initrd /ramdisk.img${GPUFW_INITRD}
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
           initcall_blacklist=amd_gpio_driver_init \\
           androidboot.pc_install=1 \\
           androidboot.pc_install_confirm=ERASE \\
           sysctl.kernel.dmesg_restrict=0 \\
           video=Virtual-1:${GUEST_MODE:-1600x900} \\
           ${NOUVEAU_ARG} \\
           console=ttyS0,115200 console=tty0 loglevel=4 ${KERNEL_EXTRA_ARGS:-}
    initrd /ramdisk.img${GPUFW_INITRD}
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
[[ -n "$GPUFW_INITRD" ]] && mcopy -i "$WORK/esp.img" "$WORK/gpufw.img" ::/gpufw.img
ok "ESP populated: BOOTX64.EFI, grub.cfg, bzImage, ramdisk.img${GPUFW_INITRD:+, gpufw.img}"

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
