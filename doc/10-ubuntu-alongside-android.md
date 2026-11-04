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
   - Call `sethostname("ubuntu")`, then `pivot_root`.
   - Make `/proc/sys` and `/proc/sysrq-trigger` read-only, so Ubuntu cannot change Android's
     kernel settings.
   - Remove from the bounding set every capability that reaches past the namespaces:
     `SYS_MODULE`, `SYS_TIME`, `SYS_RAWIO`, `MKNOD`, `DAC_READ_SEARCH`, `NET_ADMIN`,
     `MAC_ADMIN`, `MAC_OVERRIDE`, `SYSLOG`, `WAKE_ALARM`, `BLOCK_SUSPEND`, `AUDIT_CONTROL` and
     `SYS_PACCT`. `DAC_READ_SEARCH` matters because `FHANDLE=y` makes `open_by_handle_at()`
     available, and with that capability it can walk out of a mount namespace. `NET_ADMIN`
     goes because the network namespace is Android's.
   - Set `PR_SET_PDEATHSIG` to SIGKILL. If init SIGKILLs the launcher, the whole Ubuntu
     namespace dies with it instead of running unsupervised.
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
| Crashes | Any other exit | Restarts it after 1, 5, then 30 s. A fourth crash within 5 minutes exits 1 and sets `vendor.ubuntu.state=failed`. |
| (Android sends SIGTERM) | — | Sends SIGRTMIN+3 to the child, waits 20 s, then sends SIGKILL to the namespace (R8) |

The launcher publishes `vendor.ubuntu.state` as `starting`, `running`, `stopped` or `failed`. A
future pclauncher tile can read it.

### 3.5 cgroups (R4)

Android mounts cgroup v2 at `/sys/fs/cgroup` and v1 controllers under `/dev`, per `cgroups.json`
(doc/03-kernel.md). The launcher creates `/sys/fs/cgroup/ubuntu`, enables `memory` and `pids` on it
and sets ceilings. `cpu` is left out because Android mounts it as v1, and a controller cannot be
on both hierarchies at once. The defaults are `memory.max` at 75% of RAM and `pids.max` at 8192, both
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
**partition 6**, and the disk grows by its size, so userdata keeps its share and partitions 1 to
5 never move. fstab uses by-name paths, so nothing else changes. Android never mounts it. Only
the launcher does, in its own namespace. Partition 5 then gets an explicit size instead of
`0:0`.

`tools/write-usb.sh` keeps userdata by writing only partitions 1 to 3 into an existing GPT.
That GPT has no partition 6, so the **first** write of an Ubuntu image needs `--wipe-data`.

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

- [x] `config/pc_x86_64.fragment`: `CONFIG_FHANDLE=y`, `CONFIG_USER_NS=y`, with a comment block
- [x] `tools/mkubuntu.sh` and its masking list (3.8)
- [x] `tools/mkdisk.sh`: optional partition 6 and the `Android + Ubuntu` GRUB entry (3.9)
- [x] `pc_ubuntu_launch.c`, plus `pc_ubuntu_init.c` (section 5), with host unit tests for every
      decision function: the exit-signal table, backoff, meminfo, the cgroup writer, the netlink
      gateway parser and resolv.conf (`ubuntu/run_tests.sh`, also `pc_ubuntu_launch_test`) (R11)
- [x] rc service plus sepolicy, with `ubuntu` permissive (3.7)
- **Accept** (2026-11-03: everything above is built; in QEMU, systemd reached
  multi-user, see section 5):
  - [ ] The default GRUB entry boots exactly as on `main`: no `vendor.ubuntu` started, same
        `sys.boot_completed` time within ±1 s (R1, R2).
  - [x] The `Android + Ubuntu` entry runs `adb shell getprop vendor.ubuntu.state` and gets
        `running`, and `ssh amar@<laptop>` gets a shell (HP laptop, after fix 1).
  - [x] `systemctl is-system-running` reports `running` (HP laptop, after fix 1) (R3).
  - [x] `apt update && apt install htop` works over Android's WiFi (after fixes 2 and 3).
  - [x] Inside Ubuntu, `reboot` restarts it and `poweroff` stops it. A crash, `kill -9 <systemd>`
        from Android, is restarted by the backoff. Android stays up through all three (R4, R5).
        Not `kill -SEGV 1`: systemd catches SIGSEGV as PID 1 and freezes rather than exiting.
  - [x] Shutting Android down halts Ubuntu gracefully, and ext4 is clean on the next boot (R8).
        HP laptop: init waited 0.218 s for the halt, and the journal reaches `halt.target`.

### Step 2: good neighbour (1 week)

- [ ] `ubuntu` domain enforcing. Every allow rule has a reason, and every neverallow collision is
      written up in section 5.
- [ ] cgroup ceilings, with a fork bomb and a `stress-ng --vm` test (R4)
- [ ] A proper DNS fix (3.6), chosen and implemented
- [ ] Recheck the `USER_NS` exposure on the Android side
- **Accept:** CTS `CtsSecurityTestCases` matches `main`, a fork bomb in Ubuntu leaves pclauncher
  responsive, and there are zero `avc: denied` lines for `ubuntu` during a full boot plus `apt
  upgrade`.

### Step 3: Ubuntu on screen (3 to 4 weeks), started 2026-11-04

The user asked for this before step 2. The SELinux decision only changes policy files, so the
device work does not wait for it. Model A (screen switching) comes first. Four milestones, each
of which boots:

**M1. GPU render node and desktop packages. Done 2026-11-04 on the ZBook.** `eglinfo -B` as
`amar` reports "AMD Radeon 780M Graphics (radeonsi, phoenix, LLVM 20.1.2, DRM 3.64,
7.2.0-rc6-…)" for core and ES profiles. `vulkaninfo` reports "AMD Radeon 780M Graphics (RADV
PHOENIX)". `ubuntu-desktop-minimal` installed with 0 errors (GNOME Shell 46, 3.5 GB). Found on
the way:
- `/dev/dri` was 0700 and Mesa silently fell back to llvmpipe.
- `/sys/fs/cgroup/ubuntu` was 0700, so `user@1000.service` failed with "Failed to create
  …/init.scope control group: Permission denied".
- Both were init's umask 077, the same cause as bug 2. The launcher now calls `umask(022)` at
  start, and the cgroup chmod is tested under umask 077.
- `--halt` returned before the launcher exited, so an immediate `ctl.start` was dropped as
  "already running". It now waits for the exit.
- `tpm-udev` (needs udev) and `rtkit-daemon` were masked. rtkit's `cap_set_proc` wants
  `CAP_DAC_READ_SEARCH`, which stays dropped, and PipeWire works without rtkit.
- seat0 reports `CanGraphical=no`, as expected before M2.

The design as planned:
- The launcher recreates the Android device nodes named by `vendor.ubuntu.devices` in Ubuntu's
  `/dev`, with the same device number, before `CAP_MKNOD` is dropped. The default is
  `dri/renderD128`.
- `ub_parse_devices()` accepts only paths under `dri/`, `input/` or `snd/`, made of
  `[A-Za-z0-9_-]` components, so the property can never name a disk. It is tested.
- The render node is 0666, as on Android, because the kernel shares it between any number of
  users. Anything else is 0660 root:root until M2 decides who may open it.
- Ubuntu installs `mesa-utils`, `vulkan-tools`, `mesa-vulkan-drivers` and then
  `ubuntu-desktop-minimal`. gdm3, NetworkManager and snapd stay masked.
- Accept: `eglinfo -B` and `vulkaninfo --summary` inside Ubuntu, over ssh, name the Intel GPU
  rather than llvmpipe.

**M2. GNOME on the panel. Running 2026-11-04 on the ZBook, with input; visual check by the
user pending.**

Done, measured:
1. `setprop vendor.ubuntu.devices "dri/renderD128,dri/card0,input/event5,input/event13,input/event14"`
   passes the keyboard (event5), the touchpad (event14) and the mouse (event13).
2. `pc-udev-shim` writes the database: seat0 goes from `CanGraphical=no` to `yes`, and
   `loginctl seat-status` lists `[MASTER] drm:card0` and the three input devices.
3. `setprop vendor.hwc.master ubuntu` makes drm_hwcomposer (patch 0001) log `Released DRM master
   on amdgpu`.
4. `systemctl start pc-gnome` gives logind session 9 on seat0, active. gnome-shell logs `Added
   device '/dev/dri/card0' (amdgpu) using atomic mode setting` and `GPU /dev/dri/card0 selected
   primary from builtin panel presence`, and holds fds on card0, event5, event13 and event14.
5. `setprop vendor.hwc.master android` logs `Retook DRM master on amdgpu, cleared 6 planes`. The
   composer and SurfaceFlinger kept their PIDs throughout.

Found on the way:
- logind's `TakeDevice` answered `ENODEV` for every input device until the parent `inputN`
  carried the `seat` tag too. Ubuntu's `71-seat.rules` tags the parent, not `eventN`. The shim
  now writes `+input:inputN` entries.
- The remaining gnome-shell errors are expected: there is no RTKit, because it is masked, and
  no GDM to register with.

Still open in M2: Android keeps reading the same keyboard and touchpad, so keys reach both
systems. Disabling Android's input devices is M3.

The design as planned:
- Pass `dri/card0` and the keyboard and touchpad `input/event*` nodes.
- **No VTs and no udev in the container.** logind, mutter and libinput all find devices through
  udev: tags `seat`, `master-of-seat` and `uaccess`, plus `ID_INPUT*` properties. libinput
  ignores an input device without `ID_INPUT=1`.
- Plan: a `pc-udev-shim.service` inside Ubuntu writes `/run/udev/data/c<maj>:<min>` for each
  passed node. The input properties come from `udevadm test-builtin input_id`, and the tags are
  written by hand. `/sys` is read-only but readable, which is all libudev's enumeration needs.
- The GNOME session runs as a system unit with `User=amar`, `PAMName=login`, `XDG_SEAT=seat0`
  and `XDG_SESSION_TYPE=wayland`, so pam_systemd registers a logind session on seat0. That seat
  has no VTs, so the session is activated with `loginctl activate`.
- logind opens `card0` and sets DRM master for the active session. mutter takes its devices
  through `TakeDevice`.
- For M2 only, Android's compositor must not hold master. The simplest test is booting with
  `ro.vendor.hwc.drop_drm_master=1`, which drm_hwcomposer already supports
  (`drm/DrmDevice.cpp:179`): it drops master after init. That is enough to see GNOME on the
  panel. Android's own commits then fail, which is accepted on a test entry.

**M3. The hand-off.**
- **Display.** drm_hwcomposer takes master once, at init (`drm/DrmDevice.cpp:116`), and only
  ever drops it at init. A patch adds a runtime release and retake. On release it stops
  committing and calls `drmDropMaster`. On retake it calls `drmSetMaster`, does a full modeset,
  and asks SurfaceFlinger for a refresh. The trigger is a vendor property watched with
  `__system_property_wait`.
- **Ubuntu's side of the screen** is logind's. With two sessions on seat0, the GNOME one and a
  placeholder "android" session, activating one or the other makes logind set or drop master and
  pause or resume mutter's input devices. That is the same mechanism desktop Linux uses between a
  login screen and a session.
- **Input.** Android's InputFlinger reads every evdev node, so while Ubuntu has the screen each
  key would reach both systems. `IInputManager.disableInputDevice(id)` (InputManagerService:1165)
  closes the device's fd in EventHub (`EventHub::Device::disable()` calls `close()`). It needs
  the signature permission `DISABLE_INPUT_DEVICE`, and pclauncher is platform-signed, so
  pclauncher can switch Android's keyboard and touchpad off and on with no InputFlinger patch.
- **Switching to Ubuntu:**
  1. A pclauncher key combo or tile disables Android's input devices.
  2. hwc releases master.
  3. `loginctl activate <gnome>` runs inside Ubuntu.
- **Switching back:** a GNOME shortcut activates the placeholder session, so logind drops master
  and revokes input. The launcher hears about it on a socket bind-mounted into Ubuntu's
  `/run/pc-android`, hwc retakes master, and pclauncher re-enables input.
- **Open: the control path from pclauncher (system_app) to vendor code.** pclauncher cannot set a
  `vendor_` property (coredomain), and it cannot reach a vendor socket. The choice is between a
  system-owned property type that vendor may read, and a small vendor AIDL service. It is
  decided at the start of M3.

**M3 done on the ZBook, 2026-11-04.** The user confirmed: Ctrl+Alt+F2 and Ctrl+Alt+F1 switch
the panel between GNOME and Android, and the keyboard works in GNOME.

**Details of that run (Ubuntu upgraded to 26.04.1 first: systemd 259, GNOME 50.1).**
- The launcher made `pc-ubuntu-input-0..2` (event15 to 17) from event5, event13 and event14.
  Android logged `EventHub: ignoring event id /dev/input/event15 driver pc-ubuntu-input-0` for
  each, and gnome-shell holds only the copies.
- `setprop vendor.ubuntu.screen ubuntu` logged `screen: switching to Ubuntu`, then `Released DRM
  master`, then `pc-seat ubuntu: done`, all within 250 ms. The GNOME session is active on
  seat0.
- When `pc-seat` failed, the fail-safe gave the screen straight back to Android (`Retook DRM
  master … cleared 6 planes`).

Four problems found on the way:
1. **GNOME 50's `gnome-session`** only starts `gnome-session@ubuntu.target` and exits. The
   session monitor then ends the session, because its leader is gone. `pc-gnome.service` now
   keeps a leader alive (`gnome-session …; exec sleep infinity`).
2. **systemd 25x** moves a PAM session's processes into `session-<id>.scope`, so the leader's
   cgroup no longer names the unit. `pc-seat` finds sessions by type instead: GNOME is
   `wayland`, the placeholder `unspecified`.
3. **`pc-seat` run from Android's PID namespace** failed in about 50 ms and logged nothing.
   `loginctl` talks to Ubuntu's D-Bus and logind, which identify the caller by PID. The
   launcher now also joins Ubuntu's PID namespace (setns, then a second fork), and logs the
   script's exit code and output.
4. **A GNOME started while Android held master** got `EBUSY` on card0 and died, leaving an
   empty session alive. `pc-seat ubuntu` now restarts pc-gnome when gnome-shell is not running.

Also masked: `netplan-configure.service`, which is new in 26.04, fails here, and would
configure Android's interfaces.

**M4. Sound bridge. Working on the ZBook, 2026-11-04: the user heard Ubuntu's sound on the
laptop speakers (first run by hand).**
- **Ubuntu:** `tools/ubuntu-rootfs/etc/pipewire/pipewire.conf.d/pc-android.conf` makes a virtual
  sink, "Android speakers" (`support.null-audio-sink`, priority 2000, so it is the default).
  `libpipewire-module-protocol-simple` serves its monitor as raw S16LE 48 kHz stereo on
  `127.0.0.1:4711`, loopback only. `wpctl status` shows `* 33. Android speakers`, and
  `ss -ltn` shows the port listening.
- **Android:** `pc_ubuntu_audio` (system_ext, because libaaudio is a framework library)
  connects to it and writes 10 ms blocks to an AAudio media stream. After 2 s of digital
  silence it pauses the stream, so the output can go to standby (`ub_pcm_silent`, tested). The
  rc service `pc-ubuntu-audio` runs while `vendor.ubuntu.state=running`.
- **Seen:** `pw-play` in Ubuntu produced `pc_ubuntu_audio: Ubuntu is playing`. AudioFlinger then
  showed `Standby: no` and an active track for the bridge, with frames written to the ALC245
  output (card 1, device 0).
- **Not done yet:** the binary was run by hand from `/data/local/tmp`. The rc service and the
  system_ext install arrive with the next image. Microphone (Ubuntu recording through Android)
  is the reverse direction, and is still to do.

The plan as written:
- PipeWire in Ubuntu sends its mix over a socket to an Android-side service that plays it
  through AAudio, so both systems are heard together.
- The open Android audio boot race (silent until audioserver restarts) is fixed first.

### Step 4, optional: Ubuntu windows on the Android desktop (5 to 8 weeks)

This needs a Wayland-to-SurfaceFlinger bridge. It will not start before step 3 has shipped.

---

## 5. Findings log

Record what actually happened at each step: dates, commits, denials hit and how each was
resolved. This follows the 09-multi-display rule: nothing here is inferred.

### Step 1, 2026-11-03

**Kernel.** `CONFIG_FHANDLE=y` and `CONFIG_USER_NS=y` were added to `config/pc_x86_64.fragment`,
and both are in the built `linux/.config`. No patch was needed.

**One file type cannot be both the entrypoint and Ubuntu's files.** The first policy gave the
whole partition one type, with `exec_type` and `vendor_file_type`, so that exec'ing systemd
could be the domain transition. checkpolicy rejected it on three neverallow rules in
`private/domain.te`: line 802 forbids writing those types, and lines 810 and 2286 forbid
mounting on them. The fix uses two types:
- `ubuntu_file` is a plain type for the partition.
- `ubuntu_exec` labels `/vendor/bin/pc_ubuntu_init`, a 1 kB freestanding static binary that
  only execs `/sbin/init`.

The launcher opens it `O_PATH` before `pivot_root` and runs it with `execveat(AT_EMPTY_PATH)`,
so it runs inside the Ubuntu root although it lives on `/vendor`. It has to be freestanding.
This tree has no static vendor libc variant: `static_executable` fails with "dependency libc
missing variant". A dynamic binary would need `/system/bin/linker64`, which the Ubuntu root
does not have.

**Step 2 blocker: an enforcing `ubuntu` domain cannot run its own binaries under stock AOSP
policy.** `private/domain.te:1982` forbids every domain except apps, shell, su and the
zygotes to *execute* a file unless its type is `system_file_type`, `vendor_file_type` or
`exec_type`. `domain.te:802` forbids *writing* files of exactly those types, and its only
exemptions are `kernel` (userdebug), `asan_extract` and `overlay_remounter`. So no allow rule
can let Ubuntu both run `/usr/bin/*` and let dpkg replace it. Step 1 is unaffected, because
`ubuntu` is permissive and needs no allow rule. Step 2 must pick one of these:

| Option | Cost |
|---|---|
| A. Keep `ubuntu` permissive for good. Android domains stay enforcing, and the Ubuntu side is confined by namespaces, dropped capabilities and DAC only. | Userdebug only: user builds reject permissive domains at build time |
| B. Carry a `system/sepolicy` patch that exempts `ubuntu` from lines 802 and 1982, as AOSP itself does for `overlay_remounter` | One more patch in `patches/android/`. CTS `SELinuxNeverallowRulesTest` would flag it. |
| C. Mount `/usr` from a read-only image labelled `exec_type`, and keep the rest writable | dpkg can no longer update `/usr`. Upgrades become image swaps. |

**Boot test in QEMU, 2026-11-03.** The T7 was not attached, so the test ran in QEMU/KVM with
an image built by `UBUNTU_IMG=out/ubuntu.img GRUB_DEFAULT=1 ./build.sh image`. The Ubuntu image
was 4 GiB, minbase plus the step 1 packages, from `tools/mkubuntu.sh`: a 130 MB rootfs in 214
seconds, rootless.

The launcher and systemd worked:
- `init: processing action (ro.boot.ubuntu=1 && post-fs-data)` then `starting service
  'vendor.ubuntu'` at 15.08 s of uptime.
- The launcher logged `state starting`, `dns: 1.1.1.1`, `systemd started, pid 815` and
  `state running` within 24 ms.
- The QEMU guest had no network yet (see below), so the gateway lookup found no default route
  and fell back as designed.
- Ubuntu's own journal was read afterwards from partition 6 on the host, with `debugfs rdump`
  and `journalctl --directory`. systemd ran as PID 1, with hostname `ubuntu` and a generated
  machine-id. It reached `multi-user.target` and `graphical.target`, and logged `Startup
  finished in 300ms`.
- Running were journald (persistent journal on the partition), dbus, logind ("New seat
  seat0") and `ssh.socket`.
- There was **one warning**: `systemd-logind.service: bpf-firewall: Attaching egress BPF
  program ... failed: Operation not permitted`. That is the expected cost of dropping
  `CAP_NET_ADMIN`, because cgroup-skb BPF needs it. It only affects units with `IPAddressDeny=`.
- The permissive `ubuntu` domain produced 25,395 denials, from systemd, tmpfiles, ldconfig,
  logind, journald, dbus and others. They are kept for step 2's audit2allow.

**What could not be tested in QEMU: anything that needs Android's framework.** On this image
SurfaceFlinger aborts in a loop:

    Abort message: 'Failed to create a valid texture. [...]:[384,384] isProtected:0 isWriteable:1 format:1'
    #03 ... GaneshBackendTexture::GaneshBackendTexture(...)

So system_server never starts. That takes out two things Ubuntu's checks depend on:
- **adb.** adbd waits for the framework (`Expecting lifecycle message over adbdauth`) and stays
  `offline`.
- **The guest network.** On Android, system_server configures `eth0`. ssh reached QEMU's port
  forward but timed out waiting for the banner, because the guest had no IP.

**This is not caused by this branch.** The base commit of `aosp_ubuntu` (`629e6ff`, main plus
documents) was rebuilt and tested the same day with `./build.sh test`. It gave the same result:
257 texture aborts, zygote_secondary restarting 129 times, and no `boot_completed`. The last
good QEMU runs were on 2026-09-10, which had 14 to 36 aborts per boot but did complete. QEMU
10.2.1 and virglrenderer 1.2.0 on the host have not changed since August. Between those dates
there are about 15 graphics commits (minigbm 0010 and 0011, drm_hwcomposer 0001 and 0002, and
zink). That regression is a separate job.

Acceptance status after this run:
- R1 and R2 (default entry): the image builds without `UBUNTU_IMG` with partitions 1 to 5
  unchanged. On a default-entry boot, `vendor.ubuntu` is never started: logcat has no
  launcher line. The only matches are `flags_health_check` opening the `vendor_ubuntu_prop`
  property file, which it does for every property type. The boot-time comparison is still
  open, because neither build completes boot in QEMU.
- R3: met in the journal.
- ssh, apt, the reboot, poweroff and crash cycle, and clean shutdown: all **open**. They need
  either the QEMU regression fixed or the T7 on the laptop. (They were done on hardware the
  same day; see below.)

**On hardware, 2026-11-03: the HP laptop at 192.168.0.100, booted from the T7.** On 2026-11-04 DMI identified it as the HP ZBook Firefly 14 G11 A (AMD Ryzen 9 PRO 8945HS, Radeon 780M, amdgpu), the project's "AMD laptop". This section first said Intel Meteor Lake, which was an assumption, not a reading. Same address, same 31 GiB RAM. The T7 was
written with a keep-data write of partitions 1 to 3. Then partition 6 (`ubuntu`, 16 GiB) was
added in the free space after userdata with `sgdisk -n 6:0:+16GiB`, the image was dd'd into
it, and `resize2fs` grew it, so userdata survived. The test image had the Ubuntu entry as the
GRUB default (`GRUB_DEFAULT=1`), because the laptop keyboard cannot be relied on at the menu.

What worked first time:
- Android booted fully (`sys.boot_completed=1`), and `vendor.ubuntu.state` was `running`.
- From the workstation, `ssh amar@192.168.0.100` gave `hostname` `ubuntu`, PID 1 `systemd`, and
  `uname -r` `7.2.0-rc6-00064-g0fbb39df2ee0`, the Android kernel. `systemctl
  is-system-running` reported `running`.
- `apt-get update` fetched 34.5 MB in 29 s over the laptop's WiFi, and `apt-get install htop`
  worked.
- `apt-cache policy linux-image-generic` shows no candidate, so the kernel pin holds.
- TCP out of Ubuntu works for any uid, including `nobody`, so Android's per-UID network firewall
  does not stand in the way.
- The cgroup limits applied: `memory.max` 24637976576 (75% of 31 GiB) and `pids.max` 8192.
- Reboot inside Ubuntu restarted systemd under the same launcher in about 0.5 s.
- `poweroff` inside Ubuntu went to `stopped`, and `start vendor.ubuntu` brought it back.
- SIGKILL to systemd from Android restarted it after the 1 s backoff.
- Through all of that, Android stayed up: `boot_completed` stayed 1, and pclauncher kept its
  PID.
- From Android, `nsenter -t <systemd pid> -m -p` gives a root shell inside Ubuntu, which is the
  way in when ssh is not up. toybox's `nsenter` has no `-a`, and its `-i` failed on this kernel.

Six bugs, each found on the hardware and fixed:

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Port 22 resets: `sshd: no hostkeys available -- exiting`, then `ssh.socket` failed (start limit) | The `ExecStartPre=ssh-keygen -A` drop-in is appended *after* Ubuntu's own `ExecStartPre=sshd -t`, which fails first | `pc-ssh-hostkeys.service`, a oneshot ordered `Before=` and wanted by `ssh.service` and `ssh.socket` |
| 2 | DNS fails for every user except root, including apt's `_apt` | resolv.conf created under init's umask, so 0600 | chmod 0644 after writing, with a test under `umask(077)` |
| 3 | DNS fails for root too: resolv.conf had only `1.1.1.1` | The launcher runs at post-fs-data, before WiFi has a default route. 1.1.1.1 does not answer on this network at all, not even ping. Android's own DNS is the gateway, 192.168.0.1 | Recheck every 10 s until a gateway or `vendor.ubuntu.dns` has been written |
| 4 | Every restart logged `attach <pid> to ubuntu: Device or resource busy`, and the new systemd stayed in the launcher's cgroup with no limits | The previous systemd enabled controllers in `ubuntu/cgroup.subtree_control` and left children behind. The cgroup v2 no-internal-process rule then refuses new members | `ub_cgroup_reset()` removes the old tree, deepest first, before each start. After the fix, 0 processes sit at the root and systemd builds its tree under it |
| 5 | `stop vendor.ubuntu` killed Ubuntu outright, with no halt logged | init's `stop` is SIGKILL (`gentle_kill` gives SIGTERM for only 200 ms) | `pc_ubuntu_launch --halt`, run by `setprop vendor.ubuntu.request halt` |
| 6 | The halt was sent, but systemd ignored it for the full 20 s | `SIGRTMIN+3` compiled against bionic is signal 45: bionic's SIGRTMIN is 32 + 10 reserved. systemd's is glibc's 34 + 3 = **37** | Send 37 explicitly (`SYSTEMD_SIGHALT`) |

After the fixes:
- `--halt` stops Ubuntu in 77 ms, and the kernel logs `EXT4-fs (sda6): unmounting filesystem`.
- `setprop vendor.ubuntu.request halt` (rc trigger, as the shell user) halts it in 94 ms.
- `setprop ctl.start vendor.ubuntu` brings it back without root.

**Android shutdown, not yet graceful.** After an `adb reboot`, Ubuntu's journal for the previous
boot ends with `systemd[1]: Received SIGTERM.` and `Reexecuting.`, then stops. The cause is
`reboot.cpp`'s `StopUntrackedProcesses`, which SIGTERMs every process group outside a service
cgroup. Ubuntu's processes are all outside one, so systemd gets the signal directly, and for
PID 1 that means re-execute. 3 s later everything is SIGKILLed. ext4 still came up clean on the
next boot, with no journal recovery message, because the kernel unmounts the filesystem when
the last process in its mount namespace dies. But it is not a clean shutdown of Ubuntu. Fix,
`on shutdown && property:vendor.ubuntu.state=running → exec_start vendor.ubuntu-halt`.
`on shutdown` runs before the built-in `shutdown_done` that calls DoReboot, and `exec_start`
makes init wait.

**Verified on the second reboot.** The first reboot after pushing the rc still shut down with the
old one, because init reads rc files only at boot. The log went straight from `Clear action
queue and start shutdown trigger` to `shutdown_done`. On the next reboot:

    init: starting service 'vendor.ubuntu-halt'...
    init: SVC_EXEC service 'vendor.ubuntu-halt' pid 2804 (... u:r:ubuntu_launch:s0) started; waiting...
    pc_ubuntu_launch: stopping: asking systemd to halt
    pc_ubuntu_launch: state stopped
    init: Service 'vendor.ubuntu-halt' (pid 2804) exited with status 0 waiting took 0.218000 seconds
    init: processing action (shutdown_done)

Ubuntu's journal ends with `Reached target shutdown.target`, `Finished systemd-halt.service`,
`Reached target halt.target` and `Shutting down.`, a complete halt. sda6 mounted clean on the
next boot.

**Bug 7, found on that same boot.** The DNS recheck (fix 3) gave up on its second pass. With no
network yet, it treated "nothing found" as final and logged `dns: ` with nothing after it, so the
boot kept only `1.1.1.1`, and Ubuntu had no DNS. The decision now lives in
`ub_dns_next()` in ubuntu_lib, with a test for repeated empty passes. Verified on the next boot:
`dns: 1.1.1.1 for now, no network yet` at 05 s, three empty rechecks, then `dns: 192.168.0.1`
at 45 s, once WiFi had its route. After that, `apt-get update` worked with no workaround.
Ubuntu therefore has no working DNS for its first ~40 s, until Android's WiFi is up. Step 2's
DNS forwarder (3.6) removes that window.

**Step 1 is complete on hardware.** Every acceptance box above is ticked except the R1 boot-time
comparison, which needs a default-entry boot on the laptop next to an Ubuntu-entry one.

---

## 6. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| A neverallow rule blocks something systemd needs in an enforcing `ubuntu` domain | **Happened** (section 5): execute plus write on Ubuntu's own files | Step 2 picks option A, B or C |
| `libprocessgroup` or lmkd interferes with the foreign cgroup subtree | Low to medium | Open item in 3.5. Check it with Android under memory pressure in step 2. |
| Shared network namespace routing is wrong for unmarked traffic | Low | Already the Termux path. Fallback: veth option B. |
| Ubuntu 24.04 systemd needs a kernel feature not listed in 3.10 | Low | Step 1 boots with `systemd.log_level=debug` and reads the failed units |
| Boot-time regression for Android (R1) | Low | Ubuntu is off by default, and the trigger can move to `sys.boot_completed` |
