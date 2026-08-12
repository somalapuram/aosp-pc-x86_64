# pc_x86_64 — bare-metal x86_64 PC target

AOSP 17 on real PC hardware with Intel iGPU and AMD GPU. **Not** Cuttlefish,
**not** the goldfish emulator.

Full documentation: `~/amar/x86/doc/`, in particular
`04-device-target.md` for this directory and `08-roadmap.md` for where it sits.

## Build

```bash
cd ~/amar/x86
ANDROID_TARGET=pc_x86_64-trunk_staging-userdebug ./build.sh android
```

The kernel is built separately and is not part of this target
(`TARGET_NO_KERNEL := true`):

```bash
./build.sh kernel      # -> ~/amar/x86/linux/arch/x86/boot/bzImage
```

## Status

Early bring-up. This target is being built up incrementally; see the roadmap.

Deliberately disabled for bring-up, all of which must return before anything
ships (`doc/06-boot-and-storage.md` section 6):

| Feature | State |
|---|---|
| AVB / verified boot | off |
| dm-verity | off |
| Dynamic partitions (`super.img`) | off |
| A/B updates | off |
| Recovery | off |
| SELinux | permissive at boot |

Graphics is software-rendered for now. minigbm, drm_hwcomposer and Mesa for
Intel/AMD land in roadmap phases 5 and 6 — see `doc/05-graphics.md`, which
also records why Mesa is the hard part.

## Layout

| File | Purpose |
|---|---|
| `../AndroidProducts.mk` | Registers the lunch combo |
| `pc_x86_64.mk` | Product definition |
| `BoardConfig.mk` | Board/partition/image configuration |
| `device.mk` | Packages, properties, copied files |
| `fstab.pc_x86_64` | Non-dynamic ext4 mounts by GPT label |
| `init.pc_x86_64.rc` | Device init |
| `ueventd.pc_x86_64.rc` | Device node ownership |
| `manifest.xml` | VINTF — only HALs actually provided |
| `sepolicy/` | Vendor SELinux policy |
