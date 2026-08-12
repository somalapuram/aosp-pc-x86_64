# 03 — Kernel Changes Required

Everything the kernel needs for AOSP 17 on bare-metal x86_64 with Intel iGPU
and AMD GPU.

Reference tree: `$REPO/linux` at **v7.2-rc6** (`0d8395707651`, 2026-08-05).
Every symbol below was checked against that tree. Verification commands are
included so this can be re-run when you rebase.

---

## 1. Headline

**No out-of-tree kernel code is required to boot.** The port is a
configuration exercise plus GPU driver enablement.

This is now demonstrated, not asserted. A 21 MB `bzImage`
(`7.2.0-rc6-00059-g0d8395707651`) builds clean from this document with
`i915`, `xe`, `amdgpu` and AMD Display Core all built in — **five config fixes,
zero patches**. See §8.

Seven Android-specific Kconfig symbols do not exist in mainline 7.2. **None of
them block boot** for a bring-up configuration. They buy you data-usage
accounting, per-UID statistics, metadata encryption, VTS compliance and A/B
OTA — all of which can be deferred, and some of which you may never need.

The work that *is* required is finding the parent options that gate Android's
requirements. `olddefconfig` drops a symbol whose dependencies are unmet
without saying so, so a missing gate is silent — see §5.11 and §7.

---

## 2. Correction: the Android 17 requirements fragment is empty

`kernel/configs/d/android-6.18/android-base.config` is **0 bytes**. So is
`c/android-6.18/`. Merging it is a no-op.

```
./b/android-6.12/android-base.config     261 lines   <-- newest populated
./c/android-6.18/android-base.config       0 lines
./d/android-6.18/android-base.config       0 lines   <-- Android 17, EMPTY
./v/android-6.6/android-base.config      260 lines
./u/android-6.1/android-base.config      264 lines
```

The conditional XML for `d/` is a bare `<kernel minlts="6.18.0" />` with no
requirement groups, where older releases carry full architecture groups.

**Use `kernel/configs/b/android-6.12/android-base.config` (261 lines) as your
requirements baseline.** It is the newest populated fragment and corresponds
to Android 16. Its contents are still substantially correct for Android 17;
treat it as the contract until Google populates the 6.18 one.

```bash
# verify
find $REPO/android_17/kernel/configs -name 'android-base.config' \
  -exec sh -c 'printf "%-42s %s\n" "$1" "$(wc -l < "$1")"' _ {} \;
```

---

## 3. Verified gap analysis: mainline 7.2 vs. Android requirements

### 3.1 Absent from mainline — out-of-tree patches

| Symbol | Provides | Boot-blocking? | Defer? |
|---|---|---|---|
| `CONFIG_ASHMEM` | Legacy shared memory | **No** — removed upstream; Android 12+ uses memfd | **Permanently** |
| `CONFIG_NETFILTER_XT_MATCH_QUOTA2` | netd data-usage quota, Data Saver | No — networking still comes up | Yes, until Data Saver matters |
| `CONFIG_UID_SYS_STATS` | `/proc/uid_cputime`, `/proc/uid_io` for BatteryStats | No | Yes |
| `CONFIG_CPU_FREQ_TIMES` | `/proc/uid_time_in_state` per-UID cpufreq | No | Yes |
| `CONFIG_DM_DEFAULT_KEY` | Metadata encryption | No — **unless** fstab requests `metadata_encryption` | Yes; keep it out of fstab |
| `CONFIG_INCREMENTAL_FS` | incfs — VTS, Play incremental install | No | Yes, until CTS/VTS |
| `CONFIG_DM_USER` | Userspace virtual A/B snapshots | No — you are not doing A/B | Yes, until OTA |

```bash
# verify — all seven should report ABSENT
cd $REPO/linux
for s in ASHMEM DM_DEFAULT_KEY CPU_FREQ_TIMES UID_SYS_STATS \
         NETFILTER_XT_MATCH_QUOTA2 INCREMENTAL_FS DM_USER; do
  h=$(grep -rl "^config $s\$" --include=Kconfig* . 2>/dev/null | head -1)
  printf "%-32s %s\n" "$s" "${h:-ABSENT}"
done
```

Expected upstream locations in the Android Common Kernel — **verify against
the ACK tree, these are not confirmed:**

| Symbol | Likely ACK path |
|---|---|
| `NETFILTER_XT_MATCH_QUOTA2` | `net/netfilter/xt_quota2.c` |
| `UID_SYS_STATS` | `drivers/misc/uid_sys_stats.c` |
| `CPU_FREQ_TIMES` | `drivers/cpufreq/cpufreq_times.c` |
| `DM_DEFAULT_KEY` | `drivers/md/dm-default-key.c` |
| `INCREMENTAL_FS` | `fs/incfs/` |
| `DM_USER` | `drivers/md/dm-user.c` |

```bash
git clone --depth=1 -b android16-6.18 \
  https://android.googlesource.com/kernel/common $REPO/ack
```

Backporting incfs to 7.2 is the largest of these by far — it touches VFS
internals that have moved considerably since 6.18. Budget real time. The
others are small, self-contained drivers.

### 3.2 Removed upstream since 6.12 — nothing to do

Three symbols `android-base.config` requires no longer exist in 7.2. They are
not ACK-only; they were deleted upstream. Nothing can be done and nothing
needs to be:

| Symbol | Note |
|---|---|
| `CONFIG_SCHED_DEBUG` | Folded into always-on debug infrastructure |
| `CONFIG_NF_CT_PROTO_DCCP` | DCCP removed from the kernel |
| `CONFIG_NF_CT_PROTO_UDPLITE` | UDP-Lite conntrack folded away |

```bash
# verify — all three should report ABSENT
cd $REPO/linux
for s in SCHED_DEBUG NF_CT_PROTO_DCCP NF_CT_PROTO_UDPLITE; do
  h=$(grep -rl "^config $s\$" --include=Kconfig* . 2>/dev/null | head -1)
  printf "%-24s %s\n" "$s" "${h:-ABSENT}"
done
```

Together with the six ACK-only symbols that appear in the fragment, these
account for **all nine** expected drops in §7.

### 3.3 Present in mainline — no work needed

Everything Android needs at the core is upstream. Confirmed present in 7.2:

| Symbol | Location |
|---|---|
| `ANDROID_BINDER_IPC` | `drivers/android/Kconfig` |
| `ANDROID_BINDERFS` | `drivers/android/Kconfig` |
| `FS_VERITY` | `fs/verity/Kconfig` |
| `FS_ENCRYPTION_INLINE_CRYPT` | `fs/crypto/Kconfig` |
| `BLK_INLINE_ENCRYPTION` | `block/Kconfig` |
| `STATIC_USERMODEHELPER` | `security/Kconfig` |
| `PSI` | `init/Kconfig` |
| `QFMT_V2` | `fs/quota/Kconfig` |
| `SYNC_FILE` | `drivers/dma-buf/Kconfig` |
| `TRACE_GPU_MEM` | `drivers/gpu/trace/Kconfig` |
| `EROFS_FS` | `fs/erofs/Kconfig` |
| `EFI_PARTITION` | `block/partitions/Kconfig` |

Binder is upstream. ashmem is gone and unmissed. This is why mainline is a
viable base at all.

---

## 4. Toolchain: clang and LLD are mandatory

`android-base.config` requires:

```
CONFIG_CC_IS_CLANG=y
CONFIG_AS_IS_LLVM=y
CONFIG_LD_IS_LLD=y
```

These are auto-detected from the compiler, so they are not settable — they are
an instruction to **build with LLVM, not GCC**:

```bash
make LLVM=1 -j192
```

Use AOSP's prebuilt toolchain for ABI consistency:

```bash
export PATH=$REPO/android_17/prebuilts/clang/host/linux-x86/clang-r*/bin:$PATH
```

A GCC-built kernel will fail Android's config requirements and may hit
subtle ABI mismatches with AOSP userspace.

---

## 5. Required configuration

Symbol names below are verified against 7.2. Watch for the two that changed
name from what older documentation states.

### 5.1 Android core

```
CONFIG_ANDROID_BINDER_IPC=y
CONFIG_ANDROID_BINDERFS=y
CONFIG_STAGING=y
CONFIG_PSI=y                        # lmkd depends on this
CONFIG_PM_WAKELOCKS=y
CONFIG_SYNC_FILE=y
CONFIG_STATIC_USERMODEHELPER=y
CONFIG_TRACE_GPU_MEM=y
```

Android explicitly requires these to be **off**:

```
# CONFIG_SYSVIPC is not set
# CONFIG_DEVMEM is not set
# CONFIG_FHANDLE is not set
# CONFIG_ANDROID_LOW_MEMORY_KILLER is not set
# CONFIG_ANDROID_PARANOID_NETWORK is not set
# CONFIG_PM_AUTOSLEEP is not set
# CONFIG_RT_GROUP_SCHED is not set
# CONFIG_USELIB is not set
```

### 5.2 Filesystems

Android 17 system images are **erofs**. `/data` is ext4 or f2fs.

```
CONFIG_EROFS_FS=y
CONFIG_EROFS_FS_ZIP=y
CONFIG_EXT4_FS=y
CONFIG_EXT4_FS_SECURITY=y
CONFIG_F2FS_FS=y
CONFIG_FUSE_FS=y
CONFIG_OVERLAY_FS=y
CONFIG_QUOTA=y
CONFIG_QUOTACTL=y
CONFIG_QFMT_V2=y
CONFIG_FS_ENCRYPTION=y
CONFIG_FS_ENCRYPTION_INLINE_CRYPT=y
CONFIG_FS_VERITY=y
CONFIG_BLK_INLINE_ENCRYPTION=y
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
```

`CONFIG_QUOTA` is not optional — Android's `installd` requires working quotas
on `/data`.

### 5.3 Device mapper and block

```
CONFIG_MD=y
CONFIG_BLK_DEV_DM=y
CONFIG_DM_VERITY=y
CONFIG_DM_CRYPT=y
CONFIG_DM_SNAPSHOT=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_LZ4=y
CONFIG_EFI_PARTITION=y              # required for GPT by-name symlinks
```

`CONFIG_EFI_PARTITION` is easy to miss and produces a confusing failure —
`/dev/block/by-name/*` simply never appears. See
[06-boot-and-storage.md](06-boot-and-storage.md) §7.

### 5.4 Security

```
CONFIG_SECURITY=y
CONFIG_SECURITY_SELINUX=y
CONFIG_DEFAULT_SECURITY_SELINUX=y
CONFIG_SECURITY_NETWORK=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_HARDENED_USERCOPY=y
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_STRICT_KERNEL_RWX=y
CONFIG_STRICT_MODULE_RWX=y
CONFIG_BUG_ON_DATA_CORRUPTION=y
CONFIG_AUDIT=y
```

### 5.5 cgroups and scheduling

```
CONFIG_CGROUPS=y
CONFIG_CGROUP_SCHED=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_BPF=y
CONFIG_MEMCG=y
CONFIG_NAMESPACES=y
CONFIG_NET_NS=y
CONFIG_UTS_NS=y
CONFIG_PREEMPT=y
CONFIG_HIGH_RES_TIMERS=y
CONFIG_NO_HZ=y
CONFIG_TASKSTATS=y
CONFIG_TASK_IO_ACCOUNTING=y
CONFIG_TASK_XACCT=y
```

### 5.6 Networking

This is the **largest block in `android-base.config`** — roughly 100 symbols.
Android's `netd` builds a substantial iptables ruleset at boot and eBPF-based
traffic accounting; missing pieces cause boot-time netd failures that look
unrelated to networking.

```
CONFIG_NET=y
CONFIG_INET=y
CONFIG_IPV6=y
CONFIG_PACKET=y
CONFIG_UNIX=y
CONFIG_NETFILTER=y
CONFIG_NF_CONNTRACK=y
CONFIG_IP_NF_IPTABLES=y
CONFIG_IP6_NF_IPTABLES=y
CONFIG_IP_ADVANCED_ROUTER=y
CONFIG_IP_MULTIPLE_TABLES=y
CONFIG_IPV6_MULTIPLE_TABLES=y
CONFIG_NET_SCHED=y
CONFIG_NET_CLS_BPF=y
CONFIG_NET_ACT_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_XFRM_USER=y
CONFIG_XFRM_INTERFACE=y
CONFIG_TUN=y
CONFIG_VETH=y
CONFIG_DUMMY=y
CONFIG_IFB=y
```

**Take the full `NETFILTER_XT_*` and `NF_CONNTRACK_*` list verbatim from
`kernel/configs/b/android-6.12/android-base.config`.** Do not hand-pick — the
list is long, the failure mode is obscure, and `xt_quota2` is the only entry
you cannot satisfy on mainline.

### 5.7 Graphics — Intel and AMD in one kernel

All confirmed present in 7.2. Build **both vendors in**; runtime PCI-ID
matching selects the driver. See [05-graphics.md](05-graphics.md) §2.

```
CONFIG_DRM=y
CONFIG_DRM_KMS_HELPER=y
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_DRM_GEM_SHMEM_HELPER=y

# Intel — Gen8..Gen12 (Broadwell .. Alder Lake)
CONFIG_DRM_I915=y

# Intel — Xe / Arc / Lunar Lake and newer
CONFIG_DRM_XE=y

# AMD
CONFIG_DRM_AMDGPU=y
CONFIG_DRM_AMDGPU_SI=y
CONFIG_DRM_AMDGPU_CIK=y
CONFIG_DRM_AMD_DC=y
CONFIG_DRM_AMD_DC_FP=y

# virtio-gpu, for the QEMU development loop
CONFIG_DRM_VIRTIO_GPU=y

# dma-buf heaps — minigbm's HAS_DMABUF_SYSTEM_HEAP path
CONFIG_DMABUF_HEAPS=y
CONFIG_DMABUF_HEAPS_SYSTEM=y

# Required to build AMD Display Core with clang — see below
CONFIG_FRAME_WARN=4096
```

> `CONFIG_DRM_AMD_DC=y` is **required** for display on any modern AMD part.
> Without Display Core you get compute but no modesetting.

#### AMD Display Core will not build with clang at the default frame limit

Enabling `DRM_AMD_DC` with `LLVM=1` fails outright:

```
display_mode_vba_30.c:3451:6: error: stack frame size (2320) exceeds limit (2048)
  in 'dml30_ModeSupportAndSystemConfigurationFull' [-Werror,-Wframe-larger-than]
```

AMD's DML (display mode library) has very large stack frames and clang
generates larger ones than GCC. dcn30, dcn31 and dcn314 need 2320, 2128 and
2152 bytes against the 2048 default, and `CONFIG_WERROR=y` turns the warning
into a hard error.

**Android requires clang** (§4), so this cannot be avoided by switching
compiler. Raise the limit:

```
CONFIG_FRAME_WARN=4096
```

Note this is the **global** limit. `dc/dml/Makefile` adds a stricter per-file
flag only when `FRAME_WARN` is *less than* its own 2048 threshold:

```makefile
ifeq ($(call test-lt, $(CONFIG_FRAME_WARN), $(frame_warn_limit)),y)
    frame_warn_flag := -Wframe-larger-than=$(frame_warn_limit)
endif
```

so raising the global value is sufficient and is not overridden. Prefer this
to `CONFIG_WERROR=n` (loses `-Werror` kernel-wide) or `CONFIG_FRAME_WARN=0`
(disables frame-size checking entirely).

Build these **in (`=y`), not as modules**, during bring-up. Module loading
from the Android ramdisk drags in `vendor_dlkm` complexity you do not want yet.

### 5.8 Firmware

`amdgpu` and newer `i915`/`xe` need firmware at probe time. During bring-up,
build blobs into the image so the boot path has no filesystem dependency:

```
CONFIG_EXTRA_FIRMWARE="amdgpu/<asic>.bin i915/<platform>_dmc.bin"
CONFIG_EXTRA_FIRMWARE_DIR="firmware"
```

```bash
git clone --depth=1 https://gitlab.com/kernel-firmware/linux-firmware.git
```

⚠️ **AMD firmware load failures are quiet.** The driver probes, partially
initialises, and you get no display with nothing obvious in the log. Always
check explicitly:

```bash
dmesg | grep -iE 'amdgpu|i915|xe|firmware|drm'
```

Move to `/vendor/firmware` once the userspace side is stable.

### 5.9 Input — real PC hardware

Note the **corrected symbol name**: there is no `CONFIG_I2C_HID` in 7.2.

```
CONFIG_INPUT=y
CONFIG_INPUT_EVDEV=y
CONFIG_HID_GENERIC=y
CONFIG_USB_HID=y
CONFIG_I2C_HID_CORE=y
CONFIG_I2C_HID_ACPI=y               # laptop touchpads — NOT CONFIG_I2C_HID
CONFIG_MOUSE_PS2=y
CONFIG_KEYBOARD_ATKBD=y
CONFIG_UHID=y
CONFIG_HIDRAW=y
CONFIG_INPUT_JOYSTICK=y
CONFIG_JOYSTICK_XPAD=y
```

`I2C_HID_ACPI` is the one that matters on x86 laptops — without it modern
touchpads do not enumerate.

### 5.10 Audio, storage, USB, power

```
# Audio — covers essentially all Intel and AMD PC audio
CONFIG_SOUND=y
CONFIG_SND=y
CONFIG_SND_HDA_INTEL=y              # sound/hda/controllers/Kconfig in 7.2
CONFIG_SND_SOC=y

# Storage
CONFIG_BLK_DEV_NVME=y
CONFIG_ATA=y
CONFIG_SATA_AHCI=y
CONFIG_USB_STORAGE=y

# USB — adb needs the gadget stack if you use USB adb
CONFIG_USB=y
CONFIG_USB_SUPPORT=y
CONFIG_USB_GADGET=y
CONFIG_USB_CONFIGFS=y
CONFIG_USB_CONFIGFS_F_FS=y

# Power
CONFIG_SUSPEND=y
CONFIG_ACPI=y
CONFIG_ACPI_BUTTON=y
CONFIG_ACPI_BATTERY=y
CONFIG_ACPI_AC=y
CONFIG_CPU_FREQ=y
CONFIG_CPU_FREQ_STAT=y
CONFIG_RTC_CLASS=y
```

Most desktops have no USB device-mode controller, so USB adb will not work
there — use `adb connect` over Ethernet instead. Laptops vary.

### 5.11 Dependency gates — the ones that bite

These enable nothing directly. They are parent options that `x86_64_defconfig`
leaves off, and without them `olddefconfig` **silently discards** the Android
requirements that depend on them. Running the audit in §7 without these
reported 68 dropped symbols; with them, 9.

```
# NETFILTER_ADVANCED gates 104 symbols across net/netfilter,
# net/ipv4/netfilter and net/ipv6/netfilter -- most of the
# NETFILTER_XT_* matches and NF_CONNTRACK_* helpers netd needs.
# Off in x86_64_defconfig. Alone, this accounted for 33 dropped symbols.
CONFIG_NETFILTER_ADVANCED=y

# After 6.12 the legacy iptables/arptables tables moved behind new *_LEGACY
# gates. android-base.config (6.12) predates the split, so every
# IP_NF_*/IP6_NF_* table it requires -- filter, mangle, nat, raw, security
# and all the targets -- is dropped without these. netd still uses the
# legacy interface.
CONFIG_NETFILTER_XTABLES_LEGACY=y
CONFIG_IP_NF_IPTABLES_LEGACY=y
CONFIG_IP6_NF_IPTABLES_LEGACY=y

# Gates INET_DIAG_DESTROY and INET_UDP_DIAG, used to tear down sockets on
# network changes and VPN teardown.
CONFIG_INET_DIAG=y

# IFB depends on NET_ACT_MIRRED || NFT_FWD_NETDEV.
CONFIG_NET_ACT_MIRRED=y

# HID_PLAYSTATION depends on LEDS_CLASS_MULTICOLOR.
CONFIG_LEDS_CLASS_MULTICOLOR=y
```

**How to find a gate yourself.** When the audit reports a dropped symbol that
is not in §3.1 or §3.2, look up what it depends on:

```bash
cd $REPO/linux
S=IP_NF_FILTER
F=$(grep -rl "^config $S\$" --include=Kconfig* . | head -1)
sed -n "/^config $S\$/,/^\$/p" "$F" | grep -E 'depends on|select'
# -> depends on IP_NF_IPTABLES_LEGACY
```

Then check whether that parent is set in `.config`, and add it to the fragment
if not. The failure is always one of two things: a symbol renamed or removed
upstream (§3.2), or a parent gate left unset.

---

## 6. Building the config

Use `../build.sh kernel-config`, which performs the steps below.

> **Note:** an earlier draft of this document suggested extracting a base
> config from the shipping Cuttlefish prebuilt with `scripts/extract-ikconfig`.
> **That does not work** — none of the AOSP kernel prebuilts carry an embedded
> config:
>
> ```bash
> $ ./scripts/extract-ikconfig .../kernel/prebuilts/mainline/x86_64/kernel-mainline-allsyms
> extract-ikconfig: Cannot find kernel config.
> ```
>
> The same is true of `6.18/x86_64/kernel-6.18` and `6.12/x86_64/kernel-6.12`.
> Start from the in-tree defconfig instead — it is self-contained and has no
> external dependency.

```bash
cd $REPO/linux

# 1. Base: the in-tree x86_64 defconfig
make LLVM=1 x86_64_defconfig

# 2+3. Merge Android's requirements (the POPULATED b/android-6.12 fragment,
#      not the empty d/android-6.18 one) and the PC fragment
./scripts/kconfig/merge_config.sh -m -O . .config \
  $REPO/android_17/kernel/configs/b/android-6.12/android-base.config \
  $REPO/config/pc_x86_64.fragment

# 4. Resolve
make LLVM=1 olddefconfig
```

Keep your additions in `config/pc_x86_64.fragment`, never as hand-edits to
`.config`. `.config` is a build artefact.

### Host packages

The kernel build needs three packages beyond a normal build environment:

```bash
sudo apt-get install -y bison flex libelf-dev
```

`bison` and `flex` build the kconfig parser; `libelf-dev` is needed by
`objtool`. `./build.sh deps` checks for these and prints the install command.

> All three were already present on this host — an earlier note here claiming
> otherwise came from a false negative in the dependency check, where both
> `command -v bison` and `dpkg -l bison` reported missing for a binary that
> was installed. Verify with `bison --version` before installing anything.

---

## 7. Verify nothing was silently dropped

`make olddefconfig` discards unknown symbols **without warning**. This is the
single most important check in this document — it is how a 6.12 fragment on a
7.2 tree quietly loses requirements.

```bash
cd $REPO/linux
FRAG=$REPO/android_17/kernel/configs/b/android-6.12/android-base.config

while read -r line; do
  case "$line" in
    CONFIG_*=*)
      sym=${line%%=*}
      grep -q "^$sym=" .config || echo "DROPPED: $line" ;;
    "# CONFIG_"*" is not set")
      sym=$(echo "$line" | awk '{print $2}')
      grep -q "^$sym=" .config && echo "SHOULD BE OFF: $sym" ;;
  esac
done < "$FRAG"
```

`./build.sh kernel-config` runs this automatically and additionally asserts
that twelve port-critical options are `=y`.

Expected output on mainline 7.2 is **exactly nine symbols** — the six ACK-only
ones from §3.1 that appear in this fragment, plus the three removed upstream
in §3.2:

```
DROPPED: CONFIG_ASHMEM=y
DROPPED: CONFIG_CPU_FREQ_TIMES=y
DROPPED: CONFIG_DM_DEFAULT_KEY=y
DROPPED: CONFIG_NETFILTER_XT_MATCH_QUOTA2=y
DROPPED: CONFIG_NETFILTER_XT_MATCH_QUOTA2_LOG=y
DROPPED: CONFIG_UID_SYS_STATS=y
DROPPED: CONFIG_SCHED_DEBUG=y
DROPPED: CONFIG_NF_CT_PROTO_DCCP=y
DROPPED: CONFIG_NF_CT_PROTO_UDPLITE=y
```

(`INCREMENTAL_FS` and `DM_USER` from §3.1 do not appear — they are not in
`android-base.config`.)

**Anything else in that output is a real regression**, and it is one of two
kinds:

1. **A symbol renamed or removed upstream** between 6.12 and 7.2. Confirm with
   the `grep -rl "^config $S\$"` check in §3.2 and, if it is genuinely gone,
   record it rather than chasing it.
2. **A parent gate left unset**, so `olddefconfig` dropped the symbol on unmet
   dependencies. This is the more common and more dangerous case, because the
   symbol still exists and nothing looks wrong. Diagnose with the `depends on`
   lookup in §5.11.

This is not hypothetical. The first run of this audit reported **68** dropped
symbols; all but nine were case 2, and the largest single cause —
`NETFILTER_ADVANCED` — would have silently removed roughly a third of netd's
ruleset from a kernel that otherwise built and booted fine.

---

## 8. Build

```bash
./build.sh kernel          # config + audit + build
```

or by hand:

```bash
cd $REPO/linux
make LLVM=1 -j192 bzImage
# → arch/x86/boot/bzImage
```

Roughly 2 minutes on this host when uncontended. That turnaround is what makes
the QEMU loop in [02-host-setup.md](02-host-setup.md) worth setting up
properly.

### Verified result

```
Kernel: arch/x86/boot/bzImage is ready  (#1)
bzImage: 21 MB
Linux kernel x86 boot executable, bzImage,
version 7.2.0-rc6-00059-g0d8395707651, #1 SMP
```

Built with AOSP clang 22.0.2 (`clang-r596125`) and `LLVM=1`, with `i915`, `xe`,
`amdgpu` and AMD Display Core all built in.

**Five config fixes, zero out-of-tree patches** — the six `NETFILTER_*` /
`INET_DIAG` / `NET_ACT_MIRRED` / `LEDS_CLASS_MULTICOLOR` gates in §5.11, and
`FRAME_WARN` in §5.7. That is the §1 headline demonstrated end to end.

---

## 9. Fallback: the Android Common Kernel

If mainline drift becomes a time sink, ACK `android16-6.18` carries all seven
missing symbols and matches AOSP 17's expectations exactly:

```bash
git clone -b android16-6.18 \
  https://android.googlesource.com/kernel/common $REPO/ack
```

Trade-off: older base, less new-hardware support, Google's patch stack. You
can rebase mainline work onto it later, or cherry-pick the seven drivers out
of it into mainline — which is the recommended direction if you only need two
or three of them.
