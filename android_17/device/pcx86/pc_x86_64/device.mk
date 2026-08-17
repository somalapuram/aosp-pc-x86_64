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
    device/pcx86/pc_x86_64/pc_debug_dump.sh:$(TARGET_COPY_OUT_VENDOR)/bin/pc_debug_dump.sh \
    device/pcx86/pc_x86_64/pc_screencap.sh:$(TARGET_COPY_OUT_VENDOR)/bin/pc_screencap.sh \
    device/pcx86/pc_x86_64/pc_stay_awake.sh:$(TARGET_COPY_OUT_VENDOR)/bin/pc_stay_awake.sh \
    device/pcx86/pc_x86_64/pc_select_egl.sh:$(TARGET_COPY_OUT_VENDOR)/bin/pc_select_egl.sh \
    device/pcx86/pc_x86_64/pc_logcat_file.sh:$(TARGET_COPY_OUT_VENDOR)/bin/pc_logcat_file.sh \
    device/pcx86/pc_x86_64/pc_kmsg_file.sh:$(TARGET_COPY_OUT_VENDOR)/bin/pc_kmsg_file.sh

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
PRODUCT_PROPERTY_OVERRIDES += \
    ro.lockscreen.disable.default=true

PRODUCT_PROPERTY_OVERRIDES += \
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
PRODUCT_PROPERTY_OVERRIDES += \
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
PRODUCT_VENDOR_PROPERTIES += \
    service.adb.tcp.port=5555 \
    persist.adb.tcp.port=5555

# Serial console is the primary debugging tool during bring-up.
PRODUCT_VENDOR_PROPERTIES += \
    ro.boot.console=ttyS0

# init.rc:83 runs `exec_start init_dev_config` during early-init, before apexd
# bootstrap. The service is `service init_dev_config ${ro.vendor.init_dev_config.path}`,
# so if that property is unset init cannot expand the path and the command
# fails -- which takes ueventd and apexd-bootstrap down with it and reboots:
#     Cannot expand path: property 'ro.vendor.init_dev_config.path' doesn't exist
#     Service 'ueventd' failed to start due to a fatal error
#     reboot: ... 'bootloader,bootstrap-apexd-failed'
#
# The hook exists for per-SKU settings and conditional APEX activation. This
# device needs neither, so point it at a no-op. Cuttlefish ships a real
# implementation at /vendor/bin/init_dev_config
# (device/google/cuttlefish/guest/commands/init_dev_config) if we ever need one.
#
# NOTE: the binary is expected to carry the init_dev_config_exec SELinux label.
# toybox_vendor does not, which is fine while booting permissive but must be
# revisited before switching to enforcing. See doc/07-hals.md section 1.
PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.init_dev_config.path=/vendor/bin/true
