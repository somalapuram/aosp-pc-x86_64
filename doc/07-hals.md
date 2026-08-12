# 07 — HAL Long Tail

Everything that is not graphics or boot. Individually small, collectively the
largest time sink in the project.

Copy from `device/google/cuttlefish/shared/` wherever possible — it is the
most complete AIDL-HAL device in the tree.

---

## Priority order

| Order | HAL | Difficulty | Notes |
|---|---|---|---|
| 1 | **SELinux vendor policy** | High (tedious) | Blocks everything. Ongoing, not a task. |
| 2 | **Input** | Low | evdev works out of the box |
| 3 | **Audio** | High | No generic ALSA AIDL HAL in tree |
| 4 | **Power / health** | Medium | sysfs-backed, real hardware semantics |
| 5 | **WiFi** | Medium | wpa_supplicant works; plumbing needed |
| 6 | **Bluetooth** | Medium | Floss over btusb HCI |
| 7 | **Camera** | Medium | UVC via external camera HAL |
| 8 | **Sensors / vibrator / NFC** | Low | Stub or omit |

---

## 1. SELinux — start immediately, finish never

`BOARD_VENDOR_SEPOLICY_DIRS += device/pcx86/pc_x86_64/sepolicy`

Copy `device/google/cuttlefish/shared/sepolicy/` as your starting point and
prune. This is by far the largest single head start Cuttlefish gives you.

**Workflow:**

```bash
# boot permissive, collect denials
adb shell dmesg | grep avc: > denials.txt
# generate candidate rules
audit2allow -i denials.txt
```

Do not blanket-allow. Each denial is information about a missing label or a
genuinely wrong access.

**Flip to enforcing early on a throwaway branch** just to size the remaining
work. Discovering the true scope at the end of the project is the classic
failure mode here.

SwiftShader specifically needs `PRODUCT_REQUIRES_INSECURE_EXECMEM_FOR_SWIFTSHADER`
and the matching policy — copy
`device/google/cuttlefish/shared/swiftshader/sepolicy/`.

---

## 2. Input — easy

Android's `EventHub` reads evdev directly. With `CONFIG_INPUT_EVDEV`,
`CONFIG_HID_GENERIC`, `CONFIG_USB_HID` and `CONFIG_I2C_HID` set, USB and
built-in keyboards, mice and touchpads work with no HAL.

What you supply:

```
device/pcx86/pc_x86_64/
├── keylayout/
│   ├── Generic.kl
│   └── AT_Translated_Set_2_keyboard.kl
└── idc/
    └── Synaptics_Touchpad.idc     # per-device tuning
```

```make
PRODUCT_COPY_FILES += \
    device/pcx86/pc_x86_64/keylayout/Generic.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/Generic.kl
```

Laptop touchpads usually need an `.idc` to get gestures and pointer scaling
right. Copy from Android-x86 or ChromeOS as a reference.

**Special keys** — lid switch, brightness, volume, airplane mode — map through
`.kl` files. Expect iteration.

---

## 3. Audio — the hardest of the long tail

There is **no ready-made generic ALSA AIDL audio HAL** in AOSP 17.

What exists:
- `hardware/libhardware/modules/audio/` — legacy stub HAL (`audio_hw.c`)
- `hardware/libhardware/modules/usbaudio/` — USB audio, actually useful
- `external/tinyalsa/` — the ALSA library Android uses
- `hardware/interfaces/audio/` — the AIDL interface definitions

Cuttlefish's audio HAL is virtio-snd based and will not transplant.

**Approach:** write an AIDL audio HAL over tinyalsa, targeting `snd_hda_intel`
(which covers essentially all Intel and AMD PC audio). Reference the USB audio
module for tinyalsa usage patterns.

Expect to handle: card/device enumeration, jack detection via
`/dev/input/event*` (headphone insert), HDMI audio routing, and per-machine
mixer paths. The mixer path problem is real — every laptop wires its codec
differently.

`alsa_ctl` / `alsa_amixer` are useful on-device debugging tools; build them in.

⚠️ **Budget more time here than feels reasonable.** Audio is where PC hardware
diversity bites hardest.

---

## 4. Power, battery, thermal

Android's health AIDL HAL has a generic sysfs implementation that reads
`/sys/class/power_supply/`, which is exactly where ACPI battery drivers
publish. This mostly works.

```make
PRODUCT_PACKAGES += android.hardware.health-service.example
```

Needed:
- **Battery/AC** — `CONFIG_ACPI_BATTERY`, `CONFIG_ACPI_AC`. Verify
  `/sys/class/power_supply/BAT0/` is populated.
- **Lid switch** — evdev `SW_LID` → suspend. Wire in `init.pc_x86_64.rc`.
- **Suspend** — `CONFIG_SUSPEND`, `CONFIG_PM_WAKELOCKS`. Android's
  `SystemSuspend` writes `/sys/power/state`. s2idle vs. S3 varies by machine.
- **Thermal** — thermal AIDL HAL over `/sys/class/thermal/`. Stub initially.
- **CPU freq** — the `schedutil` governor; Android's `power` HAL hints.

⚠️ **Suspend/resume on real hardware is a classic multi-week rabbit hole.**
It cannot be validated in a VM. Schedule it as bare-metal work.

---

## 5. WiFi

Standard Android WiFi stack works over mac80211:

```
wpa_supplicant  →  nl80211  →  mac80211  →  iwlwifi / ath / rtw
```

```make
PRODUCT_PACKAGES += \
    android.hardware.wifi-service \
    wpa_supplicant \
    hostapd

BOARD_WLAN_DEVICE := generic
WPA_SUPPLICANT_VERSION := VER_0_8_X
```

Needed:
- Kernel driver for your specific chip (`iwlwifi` for Intel, `ath10k`/`ath11k`
  for Qualcomm, `rtw88`/`rtw89` for Realtek)
- **Firmware in `/vendor/firmware/`** — most WiFi chips need blobs
- `wpa_supplicant.conf` and the interface name (`wlan0`)
- `android.hardware.wifi` feature XML in `permissions/`

Intel WiFi (`iwlwifi`) is the best-documented path and pairs naturally with an
Intel iGPU target machine.

---

## 6. Bluetooth

Android's Floss stack talks HCI over `/dev/hci*` via `btusb`.

```make
PRODUCT_PACKAGES += android.hardware.bluetooth-service.default
BOARD_HAVE_BLUETOOTH := true
```

Requires `CONFIG_BT`, `CONFIG_BT_HCIBTUSB`, and firmware. Generally works once
the kernel driver binds. Lower risk than audio or WiFi.

---

## 7. Camera

Laptop webcams are UVC. Use the external camera HAL, which speaks V4L2:

```make
PRODUCT_PACKAGES += android.hardware.camera.provider-service.external
```

Kernel: `CONFIG_USB_VIDEO_CLASS=y`, `CONFIG_MEDIA_SUPPORT=y`.

The external camera HAL handles enumeration and format negotiation. Expect
limited capability reporting compared to a phone ISP — no manual controls, no
multi-camera. Adequate for video calls.

---

## 8. Sensors, vibrator, NFC, GNSS

Desktops and most laptops have none of these. **Omit them rather than
stubbing**, and drop the corresponding feature XML from `permissions/` so
apps do not expect them.

Convertible laptops with accelerometers expose them via IIO
(`/sys/bus/iio/`); a sensors HAL over IIO is possible but low priority.

---

## 9. VINTF and feature declarations

Every HAL must be declared in `manifest.xml`, and features in `permissions/`.
Missing entries cause boot failures that look unrelated to the HAL in
question.

```bash
# on device — validate the manifest
vintf --check-compat
adb shell dumpsys package features
```

Copy `device/google/cuttlefish/shared/permissions/` and prune to what the
hardware actually has. Declaring a feature you do not have is worse than
omitting it — apps will call into it and crash.
