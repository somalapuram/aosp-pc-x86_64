#
# Device packages and configuration for the bare-metal x86_64 PC target.
#
# Kept deliberately small for the first build. HALs are added in the order
# given by doc/07-hals.md, not all at once.
#

# --- Dalvik heap -----------------------------------------------------------
# Required. Nothing else in this product's inherit chain sets dalvik.vm.heap*,
# so the runtime falls back to tiny defaults and apps die once the framework
# is actually up -- SystemUI crashed 379 times in a single boot, Settings 69:
#     E AndroidRuntime: java.lang.OutOfMemoryError: Failed to allocate a
#       32 byte allocation with 160264 free bytes and 156KB until OOM
#       at AccessibilityUserState.getShortcutTargetsLocked(...)
# This is a PC with plenty of RAM, so use the largest stock profile rather
# than Cuttlefish's phone-xhdpi-2048.
$(call inherit-product, frameworks/native/build/phone-xhdpi-6144-dalvik-heap.mk)

# --- Vendor partition base -------------------------------------------------
# Required. The product makefile inherits only system-side products
# (generic_system, handheld_system_ext, aosp_product), which install nothing
# on /vendor. base_vendor.mk supplies what a vendor partition cannot work
# without: fs_config_dirs_nonsystem / fs_config_files_nonsystem, init_vendor,
# group_vendor, passwd_vendor, gralloc.default, and the VINTF data modules.
#
# In particular it installs vendor_compatibility_matrix.xml, the soong
# vintf_data module that generates /vendor/compatibility_matrix.xml. Setting
# DEVICE_MATRIX_FILE alone is not enough -- that only supplies the module's
# INPUT. Without this inherit, checkvintf fails with:
#   getDeviceCompatibilityMatrix: -2 ... Cannot read vendor/compatibility_matrix.xml
$(call inherit-product, $(SRC_TARGET_DIR)/product/base_vendor.mk)

# --- Boot configuration ----------------------------------------------------
PRODUCT_COPY_FILES += \
    device/pcx86/pc_x86_64/fstab.pc_x86_64:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.pc_x86_64 \
    device/pcx86/pc_x86_64/fstab.pc_x86_64:$(TARGET_COPY_OUT_RAMDISK)/first_stage_ramdisk/fstab.pc_x86_64 \
    device/pcx86/pc_x86_64/init.pc_x86_64.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.pc_x86_64.rc \
    device/pcx86/pc_x86_64/ueventd.pc_x86_64.rc:$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc \
    device/pcx86/pc_x86_64/pc_debug_dump.sh:$(TARGET_COPY_OUT_SYSTEM_EXT)/bin/pc_debug_dump.sh \
    device/pcx86/pc_x86_64/pc_screencap.sh:$(TARGET_COPY_OUT_SYSTEM_EXT)/bin/pc_screencap.sh \
    device/pcx86/pc_x86_64/pc_stay_awake.sh:$(TARGET_COPY_OUT_SYSTEM_EXT)/bin/pc_stay_awake.sh \
    device/pcx86/pc_x86_64/pc_select_egl.sh:$(TARGET_COPY_OUT_VENDOR)/bin/pc_select_egl.sh \
    device/pcx86/pc_x86_64/pc_noop.sh:$(TARGET_COPY_OUT_VENDOR)/bin/pc_noop.sh \
    device/pcx86/pc_x86_64/pc_kmsg_vendor.sh:$(TARGET_COPY_OUT_VENDOR)/bin/pc_kmsg_vendor.sh \
    device/pcx86/pc_x86_64/pc_logcat_file.sh:$(TARGET_COPY_OUT_SYSTEM_EXT)/bin/pc_logcat_file.sh \
    device/pcx86/pc_x86_64/pc_kmsg_file.sh:$(TARGET_COPY_OUT_SYSTEM_EXT)/bin/pc_kmsg_file.sh

# --- Mesa (real GL driver) -------------------------------------------------
# Built out of tree by ./build.sh mesa -- AOSP's external/mesa3d/Android.bp
# compiles only gfxstream/virtio guest modules and no gallium driver at all, so
# Soong cannot produce these. See doc/05-graphics.md section 4.3.
#
# Declared as cc_prebuilt_library_shared in Android.bp, NOT PRODUCT_COPY_FILES:
# the build rejects ELF binaries copied that way --
#     error: found ELF prebuilt in PRODUCT_COPY_FILES,
#            use cc_prebuilt_binary / cc_prebuilt_library_shared instead
#
# Generated, not committed: mesa/ is gitignored. Run ./build.sh mesa first or
# Soong fails on missing srcs.
PRODUCT_PACKAGES += \
    libEGL_mesa \
    libGLESv2_mesa \
    libgallium_dri

# --- Graphics --------------------------------------------------------------
# drm_hwcomposer composites over a real DRM/KMS node, which is what both
# virtio-gpu (QEMU dev VM) and i915/amdgpu (metal) present. Deliberately NOT
# the goldfish ranchu composer, which is emulator-specific.
#
# Rendering is software for now. That is intentional: it keeps the Mesa work
# (doc/05-graphics.md, 1-3 months) off the critical path for first boot.
# minigbm gralloc and native Mesa land in roadmap phases 5 and 6.
PRODUCT_PACKAGES += \
    com.android.hardware.graphics.composer.drm_hwcomposer \

# gralloc. SurfaceFlinger needs an AIDL allocator service; the legacy
# gralloc.default.so that base_vendor.mk installs is not enough and SF aborts
# in a crash loop without one:
#     init: Service 'surfaceflinger' (pid N) received SIGABRT
#     init: process with updatable components 'surfaceflinger' exited 4 times
#           before boot completed
#
# The platform selects which backends drv.c compiles in, and getting it wrong
# is invisible under QEMU: backend_virtgpu is registered unconditionally, so
# 'generic' -- which defines no DRV_* at all -- appears to work in the VM and
# then fails on every real GPU:
#     E ...allocator-service.minigbm: Failed to initialize Minigbm AIDL allocator.
#     avc: denied { ioctl } path="/dev/dri/card0" ioctlcmd=0x6400   (DRM_IOCTL_VERSION)
# minigbm asks the kernel for the driver name, finds no matching backend in its
# table and exits; init restarts it every 5s forever. Nothing logs the real
# reason. The visible symptom is SurfaceFlinger: it reaches "Initializing
# graphics H/W...", blocks in buffer allocation, never publishes
# SurfaceFlingerAIDL, and the entire boot stalls behind it with no crash.
#
# 'intel' is the upstream platform for -DDRV_I915 -DDRV_XE, covering i915
# (through Alder Lake / Meteor Lake) and Xe (Lunar Lake and newer). Both
# backends are self-contained -- they need only xf86drm.h -- so no patch to
# external/minigbm is required. virtgpu stays compiled in, so the QEMU dev loop
# is unaffected by this.
#
# AMD is NOT covered here. backend_amdgpu is gated on -DDRV_AMDGPU, which no
# upstream platform sets, and amdgpu.c pulls in <amdgpu.h> and minigbm's dri.c
# loader -- meaning libdrm_amdgpu plus a Mesa gallium DRI driver. That is the
# Mesa work in doc/05-graphics.md sections 5-6, not a flag flip.
#
# 'pc' is 'intel' plus -DDRV_PC_FORCE_LINEAR. Stock 'intel' gets far enough to
# light the panel and then kills SurfaceFlinger, because minigbm hands out
# tiled buffers while the renderer is SwiftShader on the CPU:
#     E surfaceflinger: Mapping failed.
#     W Gralloc5: lock(...) failed: 3
#     E skia: ** ERROR ** Could not create EGL image, err = (0x300c)
#     F SurfaceFlinger: Failed to create a valid texture. [384,384] format:1
# i915_bo_map() only mmaps when tiling == I915_TILING_NONE, so a tiled buffer
# cannot be locked for CPU access at all. Revert to 'intel' once Mesa lands and
# the GPU, not the CPU, is doing the rendering.
$(call soong_config_set,minigbm,platform,pc)
PRODUCT_PACKAGES += \
    android.hardware.graphics.allocator-service.minigbm \
    mapper.minigbm \

# Software rendering: SwiftShader (Vulkan) + ANGLE (GLES on top of Vulkan).
#
# SwiftShader alone is NOT enough. It provides Vulkan only, while SurfaceFlinger
# loads an OpenGL ES driver through libEGL and aborts without one:
#     Abort message: 'couldn't find an OpenGL ES implementation, make sure one
#     of persist.graphics.egl, ro.hardware.egl and ro.board.platform is set'
#     #03 libEGL.so (android::Loader::open(egl_connection_t*))
# ANGLE supplies the GLES implementation, backed by SwiftShader's Vulkan.
#
# This mirrors device/linaro/dragonboard/shared/graphics/swangle/device.mk,
# the in-tree reference for a software-only graphics stack. Mesa with native
# Intel/AMD drivers replaces this in roadmap phases 5-6 (doc/05-graphics.md).
PRODUCT_REQUIRES_INSECURE_EXECMEM_FOR_SWIFTSHADER := true

PRODUCT_PACKAGES += \
    libEGL_angle \
    libGLESv1_CM_angle \
    libGLESv2_angle \
    vulkan.pastel \

# present_fence_not_reliable is required on virtio-gpu. Without it
# drm_hwcomposer returns BAD_DISPLAY from present and SurfaceFlinger fails
# every transaction, which aborts system_server's display thread:
#     E SurfaceFlinger: presentAndGetReleaseFences: present failed for
#       display N: BAD_DISPLAY (2)
#     E SurfaceFlinger: trackPendingFrame: Invalid present fence
#     F system_server: '[[BBQ] Sprite#N#0] acquireNextBufferLocked failed to
#       apply transaction. status=-2147483646'   (FAILED_TRANSACTION)
#
# Cuttlefish sets this for the same reason. An earlier revision of this file
# deliberately omitted it on the grounds that real i915/amdgpu present fences
# are reliable -- true, but irrelevant while the test platform is virtio-gpu.
# Re-evaluate when running on real hardware.
# ro.hardware.egl is NOT set here on purpose. One image runs on virtio-gpu
# (where Mesa/virgl works) and on i915 (where it does not, because iris needs
# LLVM). pc_select_egl.sh picks the right one from the DRM driver at boot,
# before any GL client starts. See that script.
PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.hwc.drm.present_fence_not_reliable=true \
    vendor.hwc.drm.device=/dev/dri/card0 \
    ro.hardware.vulkan=pastel \
    debug.hwui.renderer=skiagl

# No lock screen. This is a bring-up device that usually has nobody sitting at
# it, and the keyguard hides the launcher behind a swipe that a headless
# capture can never perform -- every screenshot taken of this port so far has
# been of the lock screen, which is not what anyone wants to look at.
PRODUCT_SYSTEM_PROPERTIES += \
    ro.lockscreen.disable.default=true

PRODUCT_SYSTEM_PROPERTIES += \
    ro.opengles.version=196608 \
    ro.sf.lcd_density=240

# Density is chosen to keep the device below the sw600dp large-screen
# threshold during bring-up. At 160 dpi the 1280x800 display reports
# sw800dp, which switches Launcher3 to its taskbar UI -- and that path NPEs
# here, crash-looping the launcher so the home screen never appears:
#     java.lang.NullPointerException: Attempt to read from field
#       'CueBarController ...'
#       at TaskbarNavButtonController.onRecentsButtonLayoutChanged
#       at NavbarButtonsViewController.onBubbleBarLocationUpdated
#       at BubbleBarController.updateBubbleBarLocationInternal
# At 240 dpi the same panel reports sw533dp and Launcher3 uses the phone
# layout, which works.
#
# A PC target will eventually want the large-screen/desktop UI, so this is a
# bring-up workaround, not a final answer -- the taskbar NPE needs its own
# investigation before raising screen size again.

# Disable StrictMode during bring-up.
#
# StrictMode is on in userdebug builds and fires constantly on a slow VM
# (main-thread disk I/O). Each violation is written to DropBox -- but
# DropBoxManagerService only starts partway through startOtherServices, so
# every early violation fails and logs a WTF with a full stack trace:
#     StrictMode: No activity manager; failed to Dropbox violation
#     E SystemServiceRegistry: No service published for: dropbox
#         at android.app.ContextImpl.getSystemService(...)   [+ full stack]
#
# That produced 107k of ~200k logcat lines in one boot, and the logging itself
# blocks system_server's main thread long enough for the watchdog to kill it:
#     Watchdog: *** WATCHDOG KILLING SYSTEM PROCESS:
#               Blocked in handler on main thread (main) for 67s
# The stack shows ordinary ULocale/Configuration/Resources work -- no deadlock,
# just starvation.
#
# Re-enable (drop this) once the platform is fast enough and the boot is clean;
# StrictMode is genuinely useful. See StrictMode.DISABLE_PROPERTY.
# PRODUCT_SYSTEM_PROPERTIES: PRODUCT_PROPERTY_OVERRIDES lands in
# vendor/build.prop on this product, so vendor_init applies it, and
# persist.sys.* is system_prop which vendor_init may not set.
PRODUCT_SYSTEM_PROPERTIES += \
    persist.sys.strictmode.disable=true

PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.opengles.aep.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.opengles.aep.xml \
    frameworks/native/data/etc/android.hardware.vulkan.compute-0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.vulkan.compute.xml \
    frameworks/native/data/etc/android.hardware.vulkan.level-1.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.vulkan.level.xml \
    frameworks/native/data/etc/android.hardware.vulkan.version-1_1.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.vulkan.version.xml

# --- Declared features -----------------------------------------------------
# app_widgets is required by Launcher3. AppWidgetManager.getInstance() returns
# null when the feature is absent, and the launcher dereferences it during
# construction, so it crash-loops and the home screen never appears:
#     java.lang.NullPointerException: Attempt to invoke virtual method
#       'java.util.List android.appwidget.AppWidgetManager...'
#       at CustomWidgetManager.getAndAddInfo(CustomWidgetManager.java:182)
#       at CustomWidgetManager.<init>(CustomWidgetManager.java:88)
#
# Declared individually rather than via handheld_core_hardware.xml: that file
# also asserts bluetooth, microphone, compass, accelerometer, location and
# android.hardware.camera -- the last meaning a built-in sensor, which is still
# not true here even with the external camera HAL below (that declares
# camera.external, a different and accurate claim). Declaring a feature that is
# absent is worse than omitting it -- apps then call into it and fail. Add
# entries here as the corresponding HALs land (doc/07-hals.md).
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.software.app_widgets.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.app_widgets.xml

# --- WiFi / Bluetooth firmware ---------------------------------------------
# AOSP ships these itself in external/linux-firmware; they just have to be
# asked for. Staging blobs from the host's linux-firmware by hand was the wrong
# instinct -- it duplicated what Soong already installs and collided with it:
#     error: overriding commands for target
#            .../vendor/firmware/iwlwifi-QuZ-a0-hr-b0-77.ucode
#
# Each module installs to intel/iwlwifi/ AND creates the flat symlink the
# driver actually requests -- iwlwifi builds a bare name with no directory
# part, while btintel asks for "intel/ibt-...". ueventd already searches
# /vendor/firmware.
#
# This is the Intel set, since the bring-up machine is an Intel laptop:
#   QuZ  AX201 / 9560      so-a0-gf-a0  AX210 / AX211
#   gl   BE200             sc-a0-wh-b0  BE201 / BE202
# Add more from external/linux-firmware/ if a machine turns up with something
# else; the list is deliberately narrow rather than all 249 MB of iwlwifi.
PRODUCT_PACKAGES += \
    linux_firmware_iwlwifi-QuZ-a0-hr-b0-77 \
    linux_firmware_iwlwifi-so-a0-gf-a0-89 \
    linux_firmware_iwlwifi-so-a0-gf-a0-pnvm \
    linux_firmware_iwlwifi-gl-c0-fm-c0-101 \
    linux_firmware_iwlwifi-gl-c0-fm-c0-c101 \
    linux_firmware_iwlwifi-gl-c0-fm-c0-pnvm \
    linux_firmware_iwlwifi-sc-a0-wh-b0-c101 \
    linux_firmware_iwlwifi-sc-a0-wh-b0-c102 \
    linux_firmware_btusb-ibt_ax201 \
    linux_firmware_btusb-ibt_ax211 \
    linux_firmware_btusb-ibt_be200 \
    linux_firmware_btpci-ibt_be211

# --- WiFi firmware: Intel "ma" family --------------------------------------
# The bring-up laptop's card is 8086:7e40, which iwlwifi claims through
# iwl_ma_mac_cfg (pcie/drv.c) -- the "ma" family, Meteor Lake CNVi. AOSP's
# external/linux-firmware has QuZ, so, gl and sc but NOT ma, so the driver
# probed, found no firmware and never bound: the PCI device showed up with an
# empty driver= and there was no wlan interface at all.
#
# All three RF variants are shipped (gf, gf4, hr) across API versions 83-89,
# 14 MB in total, because which one a given card needs depends on its RF module
# and that is not knowable from here. Flat in /vendor/firmware/: iwlwifi builds
# a bare filename with no directory part.
PRODUCT_COPY_FILES += \
    $(foreach f,$(wildcard device/pcx86/pc_x86_64/firmware/iwlwifi/*), \
        $(f):$(TARGET_COPY_OUT_VENDOR)/firmware/$(notdir $(f)))

# --- Desktop windowing -----------------------------------------------------
# This is a PC: keyboard, mouse, 2560x1600. AOSP defaults every desktop switch
# off because the reference devices are phones, so they have to be turned on
# explicitly here.
#
# Three parts, and all three are needed -- any one alone does nothing:
#   1. the framework config booleans, in overlay/ (config_isDesktopModeSupported
#      and friends);
#   2. android.software.freeform_window_management, without which the window
#      manager will not put a task in freeform at all;
#   3. window_extensions, via large_screen_common.mk, which is what activity
#      embedding and the large-screen settings layout key off.
DEVICE_PACKAGE_OVERLAYS += device/pcx86/pc_x86_64/overlay

# Put the built-in panel in WINDOWING_MODE_FREEFORM. Without this desktop mode
# is available but never entered -- see the file's own comment.
PRODUCT_COPY_FILES += \
    device/pcx86/pc_x86_64/display_settings.xml:$(TARGET_COPY_OUT_VENDOR)/etc/display_settings.xml

PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.software.freeform_window_management.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.freeform_window_management.xml

$(call inherit-product, $(SRC_TARGET_DIR)/product/large_screen_common.mk)

# --- Apps ------------------------------------------------------------------
# The AOSP app suite already arrives through aosp_product.mk -> handheld_
# product.mk (Camera2, Calendar, Contacts, DeskClock, Gallery2, Browser2,
# QuickSearchBox, messaging, Music) and handheld_system_ext.mk (Settings,
# Launcher3QuickStep, SystemUI). Nothing there needs adding; a survey of every
# AndroidManifest.xml in the tree carrying category.LAUNCHER turned up only
# automotive apps, test harnesses, library samples, and apps superseded by what
# is already installed (Gallery by Gallery2, LegacyCamera by Camera2, Launcher3
# by Launcher3QuickStep).
#
# UniversalMediaPlayer is the one genuine omission. It is a real media player
# for both audio and video, and it matters here because the Music app that
# handheld_product.mk installs has NO launcher activity at all -- its manifest
# declares only MusicPicker and MediaPlaybackService, so it can be invoked to
# pick a track but never appears on the home screen. Without this the device
# has no way to play a media file from the UI.
PRODUCT_PACKAGES += \
    UniversalMediaPlayer

# Camera: USB webcams, via the external (V4L2/UVC) provider.
#
# Without a camera feature the Camera app is built and installed but has no
# icon, which reads as "the app is missing from the build" and is not:
#     dumpsys package com.android.camera2
#       disabledComponents:
#         com.android.camera.CameraLauncher
# Camera2 ships SetActivitiesCameraReceiver, which runs on BOOT_COMPLETED and
# disables its own launcher alias unless the device declares one of
# android.hardware.camera, .camera.front or .camera.external. So the icon is
# governed by the feature, not by PRODUCT_PACKAGES.
#
# camera.external is the honest declaration for this target rather than a
# workaround for that check. A PC has no built-in sensor; it has USB ports, and
# the feature means exactly "external cameras can be connected". That keeps
# faith with the rule stated above for handheld_core_hardware.xml -- do not
# declare hardware the device does not have -- because this hardware is real
# and simply hot-pluggable. android.hardware.camera.external.xml also declares
# camera.any, so apps that ask the generic question get a true answer.
#
# The HAL enumerates /dev/video* (ueventd.pc_x86_64.rc grants cameraserver
# access) and reports no cameras when none is plugged in, which is the correct
# answer rather than a failure. Under QEMU that is the normal state unless a
# host webcam is passed through with -device usb-host.
#
# SELinux needs nothing extra: system/sepolicy/vendor/file_contexts already
# labels android.hardware.camera.provider-V[0-9]+-external-service as
# hal_camera_default_exec.
PRODUCT_PACKAGES += \
    android.hardware.camera.provider-V1-external-service

PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.camera.external.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.camera.external.xml \
    device/pcx86/pc_x86_64/external_camera_config.xml:$(TARGET_COPY_OUT_VENDOR)/etc/external_camera_config.xml

# Ethernet. This device really does have a wired NIC, and without the feature
# EthernetService never configures eth0, so the guest has no IP at all:
# nothing in logcat mentions eth0, DHCP or IpClient. That makes adb over TCP
# impossible, which in turn is the only practical way to inspect the UI while
# the virtio-gpu scanout limitation keeps the framebuffer blank
# (adb shell screencap reads SurfaceFlinger's composited output directly).
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.ethernet.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.ethernet.xml

# --- Minimal HAL set -------------------------------------------------------
# Enough to reach a shell. Everything else is doc/07-hals.md.
PRODUCT_PACKAGES += \
    android.hardware.health-service.example \
    android.hardware.health-service.example_recovery \

# KeyMint is NOT optional. keystore2 is a core service and aborts without it,
# and init fatal-reboots after it crash-loops:
#     Failed to create service android.system.keystore2.IKeystoreService/default
#     Cannot connect to Keymint
#     Error::Km(r#HARDWARE_TYPE_UNAVAILABLE)
#     init: Service 'tombstoned' exited with status 1   (repeats every 5s)
#
# This PC has no secure element or TEE, so use the software ("nonsecure")
# implementations. These are the same APEXes Cuttlefish installs. They provide
# keymint, secureclock and sharedsecret, and ship their own vintf fragments --
# so nothing needs adding to manifest.xml (see that file for why duplicating
# a fragment breaks the build).
#
# NOTE: nonsecure KeyMint stores keys without hardware backing. Fine for
# bring-up; a shipping device needs a real TEE-backed implementation.
PRODUCT_PACKAGES += \
    com.android.hardware.keymint.rust_nonsecure \
    com.android.hardware.gatekeeper.nonsecure \

# Power HAL. Not optional: system_server's HintManagerService (ADPF) throws in
# its constructor without it, which is a FATAL EXCEPTION IN SYSTEM PROCESS and
# puts system_server into a crash loop:
#     java.lang.RuntimeException: Failed to create service
#       com.android.server.power.hint.HintManagerService: service constructor threw
#     at SystemServer.startOtherServices(SystemServer.java:1689)
# Downstream this shows up as repeated "ActivityManager has died".
PRODUCT_PACKAGES += \
    android.hardware.power-service.example \

# Audio HAL. Without one audioserver null-derefs in AudioFlinger::onFirstRef
# and crash-loops (100+ times in a single boot):
#     F libc: Fatal signal 11 (SIGSEGV) ... in tid N (audioserver)
#     #00 /system/bin/audioserver (android::AudioFlinger::onFirstRef()+749)
#
# Must be the APEX, not the binary. android.hardware.audio.service-aidl.example
# is declared `installable: false` in hardware/interfaces/audio/aidl/default/
# Android.bp ("installed in apex com.android.hardware.audio"), so naming it in
# PRODUCT_PACKAGES builds it but installs nothing -- /vendor/bin/hw stays empty
# and audioserver keeps crashing with no obvious clue why.
#
# This is the AIDL reference implementation: a stub with no real routing.
# A tinyalsa/snd_hda_intel HAL for real PC audio is doc/07-hals.md section 3.
PRODUCT_PACKAGES += \
    com.android.hardware.audio \

# The APEX alone is not enough: AudioPolicyManager needs an audio policy
# configuration in /vendor/etc, and audioserver exits immediately without one.
# It produces almost no log output when it does, so the only visible symptom is
# elsewhere -- audioserver restarting every 5s (73 times in one boot) and
# system_server blocking forever in a binder call to it:
#     D AudioSystem: getService: IAudioFlingerService retrieved: 0x0
#     W Watchdog: *** WATCHDOG KILLING SYSTEM PROCESS: Blocked in handler
#                 on main thread (main) for 65s
#       at android.media.AudioSystem.isMicrophoneMuted(Native Method)
#       at com.android.server.audio.AudioService.readUserRestrictions
#       at com.android.server.audio.AudioService.<init>
#
# audio_policy_configuration_generic.xml is the generic (non-SoC) config; it
# includes primary_ and r_submix_ by reference, so both must be copied too.
# Audio configuration.
#
# Use the canonical inherit-products rather than hand-copying XML. An earlier
# revision copied audio_policy_configuration_generic.xml plus the enginedefault
# "phone" example by hand; the AIDL HAL parsed them and aborted:
#     E AHAL_Config: convertAudioStreamTypeToAidl Review Audio Policy config,
#                    -1 is not a valid audio stream type.
#     F AHAL_Config: convertAttributesGroupToAidl Line: 132 Failed (BAD_VALUE)
# The legacy example configs are not interchangeable with the AIDL HAL's
# expectations. These are what Cuttlefish inherits for the same APEX.
$(call inherit-product, frameworks/av/services/audiopolicy/audio_policy_config_vendor_1.mk)
$(call inherit-product, hardware/interfaces/audio/aidl/default/audio_effects.mk)

# The device still supplies the top-level policy config naming its modules.
#
# That file declares no modules itself -- it xi:includes them. Every include
# must exist or libxml2 resolves the document to zero modules, and main.cpp
# then simply iterates an empty list:
#     auto configs(audioPolicyConverter.releaseModuleConfigs());
#     for (auto& configPair : *configs) { createModule(...); }
# No module is registered and NOTHING is logged -- createModule only complains
# about module types it does not support, and it is never reached. The HAL
# reports "Init for Audio AIDL HAL" and looks healthy while
# android.hardware.audio.core.IModule/default never appears, audioserver waits
# on it forever, and system_server hangs in AudioService's constructor.
#
# audio_policy_config_vendor_1.mk supplies r_submix, volumes and the volume
# tables, but NOT primary (which declares the primary module -- the one that
# actually matters) or the bluetooth config. Both must be copied explicitly.
USE_XML_AUDIO_POLICY_CONF := 1
PRODUCT_COPY_FILES += \
    device/google/cuttlefish/shared/config/audio/policy/audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/primary_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/primary_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/bluetooth_with_le_audio_policy_configuration_7_0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/bluetooth_with_le_audio_policy_configuration_7_0.xml \

# --- Userspace -------------------------------------------------------------
PRODUCT_PACKAGES += \
    e2fsck \
    mke2fs \
    resize2fs \
    tune2fs \

# adb over Ethernet: most desktops have no USB device-mode controller.
# adb over TCP. PRODUCT_SYSTEM_PROPERTIES, not PRODUCT_VENDOR_PROPERTIES:
# anything in vendor/build.prop is applied by vendor_init, and these are core
# property types it may not write --
#     avc: denied { set } for property=persist.adb.tcp.port
#          scontext=u:r:vendor_init:s0 tcontext=u:object_r:default_prop:s0
# which is harmless while permissive and silently drops the setting under
# enforcing, leaving no adb at all.
PRODUCT_SYSTEM_PROPERTIES += \
    service.adb.tcp.port=5555 \
    persist.adb.tcp.port=5555

# Serial console is the primary debugging tool during bring-up.
#
# NOT set here: ro.boot.console is bootloader_prop, which vendor_init may not
# write, so from vendor/build.prop it is only ever a denial. It already arrives
# from the kernel command line -- tools/mkdisk.sh puts console=ttyS0 in
# grub.cfg, and init derives ro.boot.* from androidboot/cmdline itself.

# init.rc:83 runs `exec_start init_dev_config` during early-init, before apexd
# bootstrap. The service is `service init_dev_config ${ro.vendor.init_dev_config.path}`,
# so if that property is unset init cannot expand the path and the command
# fails -- which takes ueventd and apexd-bootstrap down with it and reboots:
#     Cannot expand path: property 'ro.vendor.init_dev_config.path' doesn't exist
#     Service 'ueventd' failed to start due to a fatal error
#     reboot: ... 'bootloader,bootstrap-apexd-failed'
#
# The hook exists for per-SKU settings and conditional APEX activation, and
# this device turns out to need exactly that: pc_select_egl.sh picks Mesa or
# ANGLE from the DRM driver that actually bound.
#
# It used to point at /vendor/bin/true, with a note that the no-op was fine
# only while permissive -- /vendor/bin/true is a symlink to toybox_vendor,
# labelled vendor_toolbox_exec, which init_dev_config may not entrypoint:
#     avc: denied { entrypoint } scontext=u:r:init_dev_config:s0
#          path="/vendor/bin/toybox_vendor" tclass=file
# So enforcing needed this replaced either way.
#
# This is also the ONLY domain that can set ro.hardware.egl. The property is a
# system_vendor_config_prop, and te_macros expands that to
#     neverallow { domain -init -vendor_init -init_dev_config } $(1):property_service set;
# so a shell or vendor_shell service of ours is refused at BUILD time, not just
# denied at runtime. Running before apexd bootstrap also puts it comfortably
# ahead of zygote, which matters because ro.* can only be set once and the
# first client to load libEGL fixes the choice.
PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.init_dev_config.path=/vendor/bin/pc_noop.sh
