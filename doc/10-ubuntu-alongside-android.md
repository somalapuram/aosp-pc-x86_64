# 10 — Ubuntu alongside Android: one kernel, Android init starts systemd

Status: **design, nothing implemented yet.** Work happens on the `aosp_ubuntu` branch. `main` and
its default GRUB entry stay unchanged until every step below passes its acceptance checks.

This document has three parts: the decision and why it was made, the requirements every step
must meet, and the step plan with acceptance boxes. Kernel facts were read from `linux/.config`
on 2026-11-03. Everything else is a plan, and it is marked that way where it has not been tried.

---

## 1. Decision

Run a full Ubuntu 24.04, with real systemd as its PID 1, on the same kernel as Android and at the
same time. **Android init starts it as an ordinary rc service** (approach 5 in the Ubuntu deck).
A small launcher puts systemd in new PID, mount, UTS, IPC and cgroup namespaces. This is the
same shape as LXC or `systemd-nspawn`.

Rejected: **the kernel starting systemd itself** (approach 4, a patch to `kernel_init()` in
`init/main.c`). Both produce the same running system, so the choice is about who starts it:

| | 4 · kernel starts it | 5 · Android init starts it |
|---|---|---|
| SELinux | Created before init loads policy, so it keeps the `kernel` domain. Android's neverallow rules forbid granting that domain what systemd needs. | `seclabel` puts it in its own `ubuntu` domain. |
| Code carried | A patch rebased on every kernel uprev | An rc service, a launcher, and policy in `device/pcx86` |
| Ubuntu crashes | Gone until a reboot | init restarts it, and Android can stop or start it |
| Boot order | Races ueventd, cgroup setup and firmware loading | Ordered after them |
| Debugging | Fails before adb exists | logcat, dmesg, adb, nsenter |
| Android fails to boot | Ubuntu still boots | Ubuntu never starts |

The only thing approach 4 does better is boot Ubuntu as a rescue system when Android is broken.
The project does not need that. Dual boot, which is approach 1, covers rescue if it is ever
needed. The launcher stays reusable either way: if approach 4 ever becomes necessary, the
kernel patch would exec the same launcher.

---

## 2. Requirements

| # | Requirement | Why |
|---|---|---|
| R1 | Android behaves identically when Ubuntu is off: same GRUB default entry, same image, same boot time | Keeps the existing product safe. Ubuntu is opt-in. |
| R2 | Ubuntu is **off unless the boot command line asks for it** (`androidboot.ubuntu=1`) | One flag to bisect with, and nothing to undo |
| R3 | systemd is PID 1 inside its own namespace and reaches `multi-user.target` with no failed units, apart from masked ones | Real Ubuntu, not a chroot. Services, journald and `systemctl` work. |
| R4 | Ubuntu can never take down Android. A crash, `poweroff`, OOM or fork bomb inside Ubuntu leaves Android up. | Android is the product. Ubuntu is a guest. |
| R5 | Android can stop and start Ubuntu without a reboot | Development speed, and a future launcher button |
| R6 | Ubuntu runs in its own SELinux domain, with enforcing mode on for Android | Never `setenforce 0`. Approach 5 exists for this. |
| R7 | Ubuntu cannot write any Android partition. It gets only its own `ubuntu` partition and explicitly shared paths. | A broken `apt` must not brick Android |
| R8 | When Android shuts down, Ubuntu shuts down cleanly first, with a bounded wait | No ext4 journal replay on every boot |
| R9 | The disk image builder makes the `ubuntu` partition only when asked to | Default images keep their current size and layout |
| R10 | Hardware owned by Android stays owned by Android: DRM master, evdev, the ALSA PCM, WiFi and netd. Ubuntu gets access only through a step that grants it deliberately (steps 3 and 4). | See the deck's conflicts slide. Two owners means neither works. |
| R11 | Every new function has a test, and every step ends with an image that boots | House rules |

---

## 3. Design

### 3.1 Boot flow

```
GRUB entry "Android + Ubuntu"   … androidboot.ubuntu=1
  └─ kernel 7.2 (unpatched)
      └─ /init (Android, PID 1)
          ├─ … ueventd, cgroups, netd, SurfaceFlinger … (unchanged)
          └─ on post-fs-data && ro.boot.ubuntu=1  →  start vendor.ubuntu
              └─ /vendor/bin/pc_ubuntu_launch        u:r:ubuntu_launch:s0
                  ├─ mount /dev/block/by-name/ubuntu → /mnt/vendor/ubuntu (context=ubuntu_file)
                  └─ clone(NEWPID|NEWNS|NEWUTS|NEWIPC|NEWCGROUP)
                      └─ pivot_root, then exec /sbin/init = systemd   u:r:ubuntu:s0, PID 1 in its namespace
```

The service starts at `post-fs-data` rather than `sys.boot_completed`. It has no dependency on
`/data` or on the framework, and this keeps it off the Android critical path that pclauncher
waits on. The trigger can move later if boot-time measurements (R1) show contention.

### 3.2 The rc service

The service goes in `device/pcx86/pc_x86_64/init.pc_x86_64.rc`. This is a sketch, not yet built:

```
service vendor.ubuntu /vendor/bin/pc_ubuntu_launch
    class late_start
    user root
    group root
    oneshot            # the launcher supervises systemd itself, see 3.4
    disabled
    seclabel u:r:ubuntu_launch:s0
    # stop: init sends SIGTERM, the launcher forwards SIGRTMIN+3 (systemd's
    # container "halt"), waits up to 20 s, then SIGKILLs the namespace.

on post-fs-data && property:ro.boot.ubuntu=1
    start vendor.ubuntu
```

Android init's own `namespace pid|mnt` option is not enough here, because it lacks UTS, IPC,
cgroup and pivot_root. So the launcher does the unshare itself.

### 3.3 The launcher, `pc_ubuntu_launch.c`

The launcher is a single C file in `device/pcx86/pc_x86_64/`, next to
`pc_audio_setup.c`. It has no Android-specific libraries apart from `liblog`, so its logic can be
unit-tested on the host. It follows systemd's container interface, published at
<https://systemd.io/CONTAINER_INTERFACE/>:

1. `mount("/dev/block/by-name/ubuntu", "/mnt/vendor/ubuntu", "ext4", MS_NODEV,
   "context=u:object_r:ubuntu_file:s0")`. The context mount gives the whole Ubuntu tree one label,
   so it needs no xattr relabel and no `file_contexts` entries for a foreign rootfs.
2. Call `clone()` with `CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC |
   CLONE_NEWCGROUP`. The network namespace is **shared** in step 1 (see 3.6).
3. In the child:
   - Run `mount --make-rprivate /`.
   - Bind the rootfs onto itself.
   - Mount `proc`, `sys` (read-only, which tells systemd it is in a container and skips udev),
     `/dev` as a tmpfs holding only `null zero full random urandom tty console ptmx` plus a
     `devpts` instance, `/run` and `/tmp` as tmpfs, and the delegated cgroup at `/sys/fs/cgroup`.
   - Call `pivot_root`, then `sethostname("ubuntu")`.
   - Exec `/sbin/init` with `container=pc-android` and `container_uuid` in the environment.
4. The parent writes the child's PID into `/sys/fs/cgroup/ubuntu/cgroup.procs` *before*
   releasing it. It does this through a pipe handshake, so every Ubuntu process is born inside the
   delegated subtree.

### 3.4 Supervision: crash, reboot, poweroff

Inside a PID namespace, `reboot(2)` kills the namespace's init with a signal that tells the
parent what was asked. The launcher uses that signal:

| systemd inside Ubuntu does | Launcher sees | Launcher does |
|---|---|---|
| `reboot` | child killed by SIGHUP | Starts systemd again |
| `poweroff`, `halt` | child killed by SIGINT | Exits 0. Ubuntu stays off until `start vendor.ubuntu`. |
| Crashes | Any other exit | Restarts it with a backoff of 1, 5 and 30 s. After 3 failures in 5 minutes, exits 1 and sets `vendor.ubuntu.state=failed`. |
| (Android sends SIGTERM) | — | Sends SIGRTMIN+3 to the child, waits 20 s, then sends SIGKILL to the namespace (R8) |

The launcher publishes `vendor.ubuntu.state` as `starting`, `running`, `stopped` or `failed`. A
future pclauncher tile can read it.

### 3.5 cgroups (R4)

Android mounts cgroup v2 at `/sys/fs/cgroup` and v1 controllers under `/dev`, per `cgroups.json`
(doc/03-kernel.md). The launcher creates `/sys/fs/cgroup/ubuntu`, enables `memory pids cpu` on it
and sets ceilings. The defaults are `memory.max` at 75% of RAM and `pids.max` at 8192, both
overridable by a property. It then delegates the subtree, and inside the cgroup namespace systemd
sees that subtree as its root.

Open item: check that `libprocessgroup` never walks or kills unknown subtrees of the v2 root.

### 3.6 Network

**Step 1 shares Android's network namespace.** Ubuntu sees `wlan0` and Android's routes, and
locally generated unmarked traffic follows Android's default-network rule. That is what Termux
relies on today, but it has not been verified here yet. Ubuntu must not manage interfaces, so
NetworkManager, systemd-networkd, wpa_supplicant and ModemManager are masked (3.8).

DNS: Android has no `/etc/resolv.conf` and no local stub resolver. In step 1, the launcher
writes `resolv.conf` from the property `vendor.ubuntu.dns`. That property defaults to the gateway
in Android's default-network routing table, and most home routers answer DNS there. The launcher
can't ask `dumpsys connectivity`, because a vendor domain may not call framework binder services.
In step 2 it gets a proper fix: either a small forwarder bound to loopback, or a private network
namespace with a veth pair (`CONFIG_VETH=y` is already on) that netd treats as a
tethered client.

### 3.7 SELinux (R6)

The new policy goes in `device/pcx86/pc_x86_64/sepolicy/`:

| Type | Purpose |
|---|---|
| `ubuntu_launch`, `ubuntu_launch_exec` | The launcher. Mounts, clones, writes cgroup files. Narrow. |
| `ubuntu` | Everything in the Ubuntu namespace. Reached by `domain_auto_trans(ubuntu_launch, ubuntu_file, ubuntu)`. |
| `ubuntu_file` | The whole Ubuntu partition, via the `context=` mount |
| `ubuntu_block_device` | `/dev/block/by-name/ubuntu`, labelled in `file_contexts` |
| `vendor_ubuntu_prop` | `vendor.ubuntu.*` |

Inside `ubuntu`, Ubuntu's own processes are not distinguished from each other, because SELinux
is not their security model. The boundary that matters is between `ubuntu` and Android. It
denies `ubuntu` every Android type except those step 3 or 4 grants explicitly: the input event
device, `gpu_device` and `audio_device`.

During step 1 only, `ubuntu` alone may be declared `permissive`. This is allowed on userdebug
builds, keeps Android enforcing, and lets denials be collected with `audit2allow`. Step 2 makes
it enforcing. Expect a few Android neverallow rules to bite, such as vendor domains executing
non-vendor files. Each one is resolved there and recorded in section 5.

### 3.8 The Ubuntu image: `tools/mkubuntu.sh`

- `mmdebstrap --variant=minbase noble` creates the rootfs. It runs rootless on the build host
  and needs no sudo. It installs `systemd systemd-sysv dbus openssh-server sudo less iproute2
  ca-certificates`, plus `ubuntu-desktop-minimal` when run with `--desktop`, which is for step 3.
- It **masks**: `systemd-udevd*`, `systemd-networkd*`, `systemd-resolved`, `systemd-timesyncd`
  (Android owns the clock), `NetworkManager`, `wpa_supplicant`, `ModemManager`, `bluetooth`,
  `snapd*`, `apparmor` (the kernel runs SELinux; see the deck's toolchain slide), `gdm3` (until
  step 3), `fstrim.timer`, `systemd-remount-fs`, and `getty@tty*`. Ubuntu gets no VTs, so login
  is through ssh, or later the console bridge.
- It pins `linux-image-*` with `apt-mark hold`, plus an `/etc/apt/preferences.d` entry, so Ubuntu
  never installs a kernel it cannot boot.
- It creates user `amar`, authorizes an ssh key passed by `--ssh-key`, and stores no password in
  the image. It writes `/etc/hostname` as `ubuntu`.
- It produces `out/ubuntu.img`, ext4, `UBUNTU_MB` in size (default 16384).

### 3.9 Disk layout: `tools/mkdisk.sh`

The `ubuntu` partition is created only when `UBUNTU_IMG` is set (R9). It is appended as
**partition 6**, carved out of userdata's share, so partition numbers 1 to 5 never move.
fstab uses by-name paths, so nothing else changes. Android never mounts it. Only the launcher
does, in its own namespace. Partition 5 then gets an explicit size instead of `0:0`.

A new GRUB entry, `Android + Ubuntu`, is the existing default entry plus `androidboot.ubuntu=1`.
It goes after the default entry, never before it (R1).

### 3.10 Kernel config: `config/pc_x86_64.fragment`

Kernel options were read from `linux/.config` on 2026-11-03:

| Option | Now | Needed | Why |
|---|---|---|---|
| `CONFIG_FHANDLE` | **off** | **y** | systemd uses `name_to_handle_at()` for mount tracking and refuses to boot without it. **This is a blocker.** |
| `CONFIG_USER_NS` | **off** | y | Unit sandboxing (`PrivateUsers=`), Flatpak, rootless podman. Ubuntu boots without it, but many units then degrade. |
| `CONFIG_FANOTIFY` | off | optional | Some desktop tools. Leave it off until something asks. |
| `NAMESPACES UTS_NS IPC_NS PID_NS NET_NS` | y | y | — |
| `CGROUPS CGROUP_PIDS CGROUP_DEVICE CGROUP_BPF BPF_SYSCALL` | y | y | systemd device policy uses BPF |
| `DEVTMPFS SIGNALFD TIMERFD EPOLL INOTIFY_USER AUTOFS_FS SECCOMP_FILTER DMIID KCMP TMPFS_POSIX_ACL` | y | y | — |
| `VETH` | y | y | Network option B in step 2 |

Turning on `FHANDLE` and `USER_NS` is the only kernel change. Both are standard upstream options
and need no patch, which is the point of approach 5. `USER_NS` widens the kernel attack surface
for Android as well. Android's own policy does not use user namespaces, so the SELinux side stays
closed, but that is checked in step 2.

---

## 4. Plan

Each step ends with an image that boots and with every box ticked before the next step starts.

### Step 1: systemd boots (1 week)

- [ ] `config/pc_x86_64.fragment`: `CONFIG_FHANDLE=y`, `CONFIG_USER_NS=y`, with a comment block
- [ ] `tools/mkubuntu.sh` and its masking list (3.8)
- [ ] `tools/mkdisk.sh`: optional partition 6 and the `Android + Ubuntu` GRUB entry (3.9)
- [ ] `pc_ubuntu_launch.c`, with host unit tests for argument parsing, the exit-signal to action
      table and the cgroup writer (R11)
- [ ] rc service plus sepolicy, with `ubuntu` permissive (3.7)
- **Accept:**
  - [ ] The default GRUB entry boots exactly as on `main`: no `vendor.ubuntu` started, same
        `sys.boot_completed` time within ±1 s (R1, R2).
  - [ ] The `Android + Ubuntu` entry runs `adb shell getprop vendor.ubuntu.state` and gets
        `running`, and `ssh amar@<laptop>` gets a shell.
  - [ ] `systemctl is-system-running` reports `running`. If it reports `degraded`, only masked
        units are listed (R3).
  - [ ] `apt update && apt install htop` works over Android's WiFi.
  - [ ] Inside Ubuntu, `reboot` restarts it, `poweroff` stops it, and `kill -SEGV 1` from Android
        is restarted by the backoff. Android stays up through all three (R4, R5).
  - [ ] Shutting Android down produces a clean ext4 on the next boot, with no journal recovery
        message in dmesg (R8).

### Step 2: good neighbour (1 week)

- [ ] `ubuntu` domain enforcing. Every allow rule has a reason, and every neverallow collision is
      written up in section 5.
- [ ] cgroup ceilings, with a fork bomb and a `stress-ng --vm` test (R4)
- [ ] A proper DNS fix (3.6), chosen and implemented
- [ ] Recheck the `USER_NS` exposure on the Android side
- **Accept:** CTS `CtsSecurityTestCases` matches `main`, a fork bomb in Ubuntu leaves pclauncher
  responsive, and there are zero `avc: denied` lines for `ubuntu` during a full boot plus `apt
  upgrade`.

### Step 3: screen switching (2 to 3 weeks)

This step needs DRM master hand-off in drm_hwcomposer, an input grab and sound handover. It gets
its own design section when step 2 is done. The Ubuntu deck's display slide is its outline.

### Step 4, optional: Ubuntu windows on the Android desktop (5 to 8 weeks)

This needs a Wayland-to-SurfaceFlinger bridge. It will not start before step 3 has shipped.

---

## 5. Findings log

Record what actually happened at each step: dates, commits, denials hit and how each was
resolved. This follows the 09-multi-display rule: nothing here is inferred.

*(empty: no step started)*

---

## 6. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| A neverallow rule blocks something systemd needs in an enforcing `ubuntu` domain | Medium | Find it in step 1 while permissive. Fallback: run that unit inside Ubuntu as masked. |
| `libprocessgroup` or lmkd interferes with the foreign cgroup subtree | Low to medium | Open item in 3.5. Check it with Android under memory pressure in step 2. |
| Shared network namespace routing is wrong for unmarked traffic | Low | Already the Termux path. Fallback: veth option B. |
| Ubuntu 24.04 systemd needs a kernel feature not listed in 3.10 | Low | Step 1 boots with `systemd.log_level=debug` and reads the failed units |
| Boot-time regression for Android (R1) | Low | Ubuntu is off by default, and the trigger can move to `sys.boot_completed` |
