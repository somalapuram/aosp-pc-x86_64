#!/usr/bin/env bash
#
# Build the Ubuntu partition image for "Ubuntu alongside Android": a full
# Ubuntu 24.04 root filesystem whose systemd runs as PID 1 of its own
# namespaces on the Android kernel, started by pc_ubuntu_launch.
# See doc/10-ubuntu-alongside-android.md section 3.8.
#
# Rootless: mmdebstrap builds in a user namespace and writes a tarball, and
# mke2fs -d turns the tarball into ext4 with ownership intact. No sudo.
#
# Usage:
#   tools/mkubuntu.sh [--desktop] [--ssh-key FILE] [--size MB] [--out FILE]
#
#   --desktop       add ubuntu-desktop-minimal (step 3; gdm stays masked)
#   --ssh-key FILE  public key for user amar (default: ~/.ssh/id_ed25519.pub,
#                   then id_rsa.pub). The image stores no password.
#   --size MB       ext4 size (default UBUNTU_MB or 16384)
#   --out FILE      default out/ubuntu.img
#
# Then:  UBUNTU_IMG=out/ubuntu.img ./build.sh image
set -euo pipefail

X86_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUITE=noble
MIRROR=${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}
SIZE_MB=${UBUNTU_MB:-16384}
OUT="$X86_ROOT/out/ubuntu.img"
DESKTOP=0
SSH_KEY=""

info() { printf '==> %s\n' "$*"; }
ok()   { printf '  ok %s\n' "$*"; }
die()  { printf ' fail %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --desktop) DESKTOP=1 ;;
        --ssh-key) SSH_KEY=$2; shift ;;
        --size)    SIZE_MB=$2; shift ;;
        --out)     OUT=$2; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

for t in mmdebstrap mke2fs; do
    command -v "$t" >/dev/null || die "$t not found (apt install mmdebstrap e2fsprogs)"
done
if [[ -z "$SSH_KEY" ]]; then
    for k in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
        [[ -f $k ]] && { SSH_KEY=$k; break; }
    done
fi
[[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] || die "no ssh public key; pass --ssh-key FILE"
grep -q '^ssh-' "$SSH_KEY" || die "$SSH_KEY does not look like a public key"

# What Ubuntu must not run, because Android owns the thing it manages (R10) or
# because it cannot work in a namespace on this kernel. Masked, not removed, so
# an apt upgrade does not bring them back.
MASK=(
    # udev: Android's ueventd owns /dev. With /sys read-only systemd would
    # skip these anyway; masking makes it explicit.
    systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket
    systemd-udev-trigger.service systemd-udev-settle.service
    # Network: the namespace is Android's in step 1 (doc 3.6).
    systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service
    systemd-resolved.service NetworkManager.service NetworkManager-wait-online.service
    wpa_supplicant.service ModemManager.service
    # Ubuntu 26.04 adds a netplan generator unit; it fails here and would
    # configure interfaces that are Android's.
    netplan-configure.service
    # Android owns the clock, Bluetooth and the console.
    systemd-timesyncd.service bluetooth.service
    getty@.service serial-getty@.service console-getty.service
    # Global kernel state shared with Android: sysctl, binfmt_misc, module
    # loading, kernel-wide pseudo filesystems.
    systemd-sysctl.service systemd-binfmt.service proc-sys-fs-binfmt_misc.automount
    proc-sys-fs-binfmt_misc.mount systemd-modules-load.service kmod-static-nodes.service
    sys-kernel-debug.mount sys-kernel-tracing.mount sys-kernel-config.mount
    sys-fs-fuse-connections.mount systemd-journald-audit.socket
    # The root filesystem is mounted by the launcher, not by Ubuntu.
    systemd-remount-fs.service fstrim.timer e2scrub_all.timer e2scrub_reap.service
    # SELinux kernel: no AppArmor, so no snaps (see the deck's toolchain slide).
    apparmor.service snapd.service snapd.socket snapd.seeded.service
    # Display is step 3: GNOME is started by a session unit, not by gdm,
    # because the container has no VTs (doc/10, step 3 M2).
    gdm3.service gdm.service
    # Needs udev, which the container does not run.
    tpm-udev.path tpm-udev.service
    # rtkit's cap_set_proc() asks for CAP_DAC_READ_SEARCH, which the launcher
    # drops on purpose (open_by_handle_at escapes a mount namespace). It only
    # gives PipeWire real-time priority, and PipeWire works without it.
    rtkit-daemon.service
)

PACKAGES=(systemd systemd-sysv dbus openssh-server sudo less iproute2 iputils-ping
          ca-certificates apt-utils bash-completion nano procps)
# --desktop: GNOME, plus Mesa userspace for the GPU render node the launcher
# passes in (vendor.ubuntu.devices). eglinfo/vulkaninfo are the M1 check.
(( DESKTOP )) && PACKAGES+=(ubuntu-desktop-minimal mesa-utils vulkan-tools mesa-vulkan-drivers)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mkubuntu.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# The hooks run as root of mmdebstrap's user namespace, which is a subuid and
# not us: mktemp's 0700 would leave it unable to enter the directory at all.
chmod 755 "$WORK"
install -m 644 "$SSH_KEY" "$WORK/authorized_keys"
# Files this project adds to Ubuntu (udev shim, GNOME session unit): see
# tools/ubuntu-rootfs/ and doc/10 step 3.
cp -a "$X86_ROOT/tools/ubuntu-rootfs" "$WORK/overlay"
chmod -R a+rX "$WORK/overlay"
printf '%s\n' "${MASK[@]}" > "$WORK/mask"

# Runs inside the new root ($1) after packages are installed.
cat > "$WORK/customize.sh" <<'HOOK'
#!/bin/sh
set -e
root=$1 work=$2

# Masks.
while read -r unit; do
    ln -sf /dev/null "$root/etc/systemd/system/$unit"
done < "$work/mask"

# Identity. machine-id is left "uninitialized" so the first boot generates it.
echo ubuntu > "$root/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 ubuntu\n::1 localhost ip6-localhost ip6-loopback\n' > "$root/etc/hosts"
echo uninitialized > "$root/etc/machine-id"
: > "$root/etc/fstab"

# resolv.conf is rewritten by pc_ubuntu_launch on every start (doc 3.6).
rm -f "$root/etc/resolv.conf"
echo "nameserver 1.1.1.1" > "$root/etc/resolv.conf"

# Ubuntu cannot boot a kernel of its own here: hold every kernel package so
# apt never pulls one in (and never runs update-initramfs for nothing).
cat > "$root/etc/apt/preferences.d/no-kernel" <<'EOF'
# Ubuntu shares the Android kernel; see doc/10-ubuntu-alongside-android.md.
Package: linux-image-* linux-modules-* linux-generic* linux-headers-generic* linux-firmware
Pin: version *
Pin-Priority: -1
EOF

# User amar, key login only, passwordless sudo (there is no password).
chroot "$root" useradd -m -s /bin/bash -G sudo,adm amar
install -d -m 700 "$root/home/amar/.ssh"
install -m 600 "$work/authorized_keys" "$root/home/amar/.ssh/authorized_keys"
chroot "$root" chown -R amar:amar /home/amar/.ssh
echo 'amar ALL=(ALL) NOPASSWD:ALL' > "$root/etc/sudoers.d/amar"
chmod 440 "$root/etc/sudoers.d/amar"

# sshd: keys only. Host keys are generated at first boot by ssh's own unit,
# so no two images share them.
cat > "$root/etc/ssh/sshd_config.d/pc-android.conf" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
# The keys must exist before ssh.service starts at all: its own first
# ExecStartPre is `sshd -t`, which fails with "no hostkeys available", so an
# ExecStartPre added by a drop-in never runs (drop-ins append). That shipped
# once and left ssh.socket failed on first boot. A unit of its own, ordered
# before, is the fix.
rm -f "$root"/etc/ssh/ssh_host_*
cat > "$root/etc/systemd/system/pc-ssh-hostkeys.service" <<'EOF'
[Unit]
Description=Generate this machine's ssh host keys on first boot
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
Before=ssh.service ssh.socket

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=ssh.service ssh.socket
EOF
for u in ssh.service ssh.socket; do
    mkdir -p "$root/etc/systemd/system/$u.wants"
    ln -sf ../pc-ssh-hostkeys.service "$root/etc/systemd/system/$u.wants/pc-ssh-hostkeys.service"
done

# Keep the journal bounded; it lives on the ubuntu partition.
mkdir -p "$root/etc/systemd/journald.conf.d"
printf '[Journal]\nSystemMaxUse=200M\n' > "$root/etc/systemd/journald.conf.d/size.conf"

# This project's own files, and the udev shim enabled (it only acts on the
# device nodes the launcher passed in, so it is harmless without a display).
cp -a "$work/overlay/." "$root/"
chown 0:0 "$root/usr/local/sbin/pc-udev-shim" "$root/usr/local/sbin/pc-seat" \
    "$root/etc/systemd/system/pc-udev-shim.service" "$root/etc/systemd/system/pc-gnome.service" \
    "$root/etc/systemd/system/pc-android-seat.service"
mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
ln -sf ../pc-android-seat.service "$root/etc/systemd/system/multi-user.target.wants/pc-android-seat.service"
mkdir -p "$root/etc/systemd/system/sysinit.target.wants"
ln -sf ../pc-udev-shim.service "$root/etc/systemd/system/sysinit.target.wants/pc-udev-shim.service"

echo "built $(date -u +%FT%TZ) by tools/mkubuntu.sh" > "$root/etc/pc-android-ubuntu"
HOOK
chmod +x "$WORK/customize.sh"

info "bootstrapping Ubuntu $SUITE ($( (( DESKTOP )) && echo desktop || echo base)) from $MIRROR"
mmdebstrap --mode=unshare --variant=minbase \
    --components=main,restricted,universe \
    --include="$(IFS=,; echo "${PACKAGES[*]}")" \
    --customize-hook="$WORK/customize.sh \"\$1\" $WORK" \
    "$SUITE" "$WORK/rootfs.tar" \
    "deb $MIRROR $SUITE main restricted universe" \
    "deb $MIRROR $SUITE-updates main restricted universe" \
    "deb http://security.ubuntu.com/ubuntu $SUITE-security main restricted universe"
ok "rootfs $(du -h "$WORK/rootfs.tar" | cut -f1) tarball"

info "making ext4, ${SIZE_MB} MiB"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
mke2fs -q -t ext4 -L ubuntu -d "$WORK/rootfs.tar" "$OUT" "${SIZE_MB}M"
ok "$OUT ($(du -h --apparent-size "$OUT" | cut -f1) apparent, $(du -h "$OUT" | cut -f1) on disk)"
echo "    next:  UBUNTU_IMG=$OUT ./build.sh image"
