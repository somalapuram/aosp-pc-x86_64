# 09 — Multi-display: a second monitor as an extended desktop

Verified on 2026-09-24 on the HP laptop (Intel Meteor Lake, i915) with an HP 527pq on HDMI-A-1,
booted from the T7: the full pclauncher desktop on the monitor, freeform windows on it, the cursor
crossing between screens. This document records **what had to change**, **what did not**, and the
mechanism at each layer, with the file and line it was read from. Nothing here is inferred.

---

## 1. The short version

Android 17 already implements an extended desktop on a second display, end to end, when three
things are true. **Two of them were missing from this port, and both were in the application and
device layers — the framework, HAL and kernel needed no change at all.**

| # | Required change | Where | Commit |
|---|---|---|---|
| 1 | A `SECONDARY_HOME` activity that is **not** `singleTask` | pclauncher manifest | `778b17d` |
| 2 | …with **its own `taskAffinity`** | pclauncher manifest | `0840e15` |
| 3 | The device feature **`android.software.activities_on_secondary_displays`** | `device.mk` | `5261945` |

Plus one non-blocking launcher change so the bar appears on the second screen (part of 1): a
home on a non-default display hosts its own bar instead of relying on the overlay service.

Without **3**, nothing is ever placed on a second display — no home, no app, and a launch aimed
at it is silently redirected to the first — regardless of 1 and 2. It was the last one found and
the only real blocker.

---

## 2. The stack, and who already did their part

```
   pclauncher  HomeActivity (display 0)      SecondaryHomeActivity (display N)    ← 1, 2
                    │                                  │
   WindowManager    startHomeOnDisplay(N) ──► canStartHomeOnDisplayArea ──► mSupportsMultiDisplay ← 3
   (system_server)  DisplayContent.updateContentMode → system decorations → freeform at hotplug
                    │
   SystemUI         status bar on display N; auto-enables the display for desktop (no dialog)
                    │
   DisplayManager   LogicalDisplay N: canHostTasks = !MIRROR_BUILT_IN_DISPLAY   (extended by default)
                    DisplayTopology: where N sits relative to 0 (cursor crossing)
                    │
   drm_hwcomposer   every connected connector → an HWC display; primary = INTERNAL, rest = EXTERNAL
                    │
   kernel (DRM)     i915 / xe / amdgpu / nouveau, all CRTCs, DP helper (MST)
```

Everything below the launcher was already correct in this port. The proof is what the monitor
showed *before* the fixes: a SystemUI status bar over black — decorations on, display extended,
and no home.

---

## 3. Layer by layer — mechanism and evidence

### 3.1 Kernel — nothing to change

All four DRM drivers are built in with `CONFIG_DRM_DISPLAY_DP_HELPER` (which carries DP-MST).
Nothing limits connectors or CRTCs. The laptop's external ports (`HDMI-A-1`, `DP-1..4`) are on
`card0` (i915), which is where they must be — the discrete NVIDIA part has no outputs.

### 3.2 drm_hwcomposer — nothing to change

`ResourceManager::UpdateFrontendDisplays()` walks every connector and binds each connected one;
`DrmHwc::BindDisplay()` hands a second one `++last_display_handle_` and raises a hotplug event.
`HwcDisplay::GetDisplayType()` reports the primary as `INTERNAL` unconditionally ("otherwise SF
will be unhappy") and any further display as `EXTERNAL`. The port is `(drmIdx << 5) | connectorIdx`.

Observed: `Display 15866911391876419509 (HWC display 1): port=1 pnpId=HPN displayName="HP 527pq"`,
`2560x1440 @ 59.94`.

### 3.3 DisplayManager — nothing to change, one flag matters

`enable_display_content_mode_management` is **ENABLED** in `trunk_staging` and in the built image
(`aconfig dump` on `all_aconfig_declarations.pb`). With it:

- an external display gets `FLAG_ALLOWS_CONTENT_MODE_SWITCH` (`LocalDisplayAdapter.java:843`);
- `canHostTasks = !MIRROR_BUILT_IN_DISPLAY` (`DisplayManagerService.java:2990`), and that Secure
  setting defaults to `0` — **extended, not mirrored, by default**;
- `InputManagerService.setDisplayTopology()` feeds the arrangement to native input, so the cursor
  crosses displays. The default arrangement puts the monitor **above** the panel
  (`position=top`); Settings → Connected devices has the arrangement view.

Do **not** touch `config_localDisplaysMirrorContent` (default `true` is the right polarity:
`shouldOwnContentOnly() = !config_localDisplaysMirrorContent`).

### 3.4 SystemUI — nothing to change

A newly connected external display is disabled pending consent
(`ExternalDisplayPolicy.shouldAutoEnable`), *unless* SystemUI enables it.
`ConnectingDisplayViewModel.handleNewPendingDisplay` computes
`isInExtendedMode = isDesktopModeSupportedOnDisplay(DEFAULT_DISPLAY)`, which is **true** here
because of the product overlay (`config_isDesktopModeSupported`,
`config_canInternalDisplayHostDesktops`), and takes `enableForDesktop()` + a toast. **No dialog.**
Do not add `persist.sys.display.enable_on_connect.external` — userdebug-only and unnecessary.

### 3.5 WindowManager — nothing to change; this is where the silence was

- `DisplayContent.updateContentMode()`: when `canHostTasks()` turns on, it calls
  `setShouldShowSystemDecorsLocked(true)` → `startSystemDecorations()` → **`startHomeOnDisplay(N)`**
  (`RootWindowContainer.java:2820`). The log line marking that moment is
  `WindowManager: Set shouldShowSystemDecors for display: displayId=N, shouldShow=true`.
- `DesktopDisplayEventHandler.onDisplayAdded` → `updateExternalDisplayWindowingMode` sets the
  external display **FREEFORM at hotplug** ("An external display should always be a freeform
  display when desktop mode is enabled"). No `display_settings.xml` `port:N` entry is needed.
  (Without that path an unlisted display would default FULLSCREEN, since
  `disable_display_force_freeform_on_pc` is ENABLED and this product does not declare
  `android.hardware.type.pc`.)
- `startHomeOnDisplay(N)` → `startHomeOnTaskDisplayArea` → `resolveSecondaryHomeActivity`:
  1. looks for `CATEGORY_SECONDARY_HOME` **in the primary home's package**;
  2. `canStartHomeOnDisplayArea` → `shouldPlaceSecondaryHomeOnDisplayArea` → checks
     `mSupportsMultiDisplay`, provisioned, CE unlocked, `isHomeSupported()`, `canHostTasks()`;
     then **refuses a `singleTask`/`singleInstance` home** ("if it requested to be single instance");
  3. else falls back to `config_secondaryHomePackage` = `com.android.launcher3` — which
     **pclauncher `overrides` out of this image**.
  Every failure in that chain returns `null` **without logging**. That is why "decorations on, no
  home" looked like nothing at all.

### 3.6 The three changes

**(1) `SecondaryHomeActivity`** — pclauncher `778b17d`. A `singleTop` subclass of `HomeActivity`
declaring `MAIN` + `SECONDARY_HOME` + `DEFAULT`, mirroring Launcher3's `SecondaryDisplayLauncher`.
`HomeActivity` stays `singleTask`. Per-display behaviour is decided at runtime from
`Activity.getDisplay()` — no ports, no config: `chromeHostFor(…, onDefaultDisplay)` makes a home
off display 0 host its own bar (the overlay service's window is display 0's; `isChromeUp` is one
global flow), and such a home never starts, stops or toggles the overlay service.
Requirement: `pclauncher/docs/requirements/shell/secondary-display-home.md`.

**(2) `android:taskAffinity="com.somalapuram.pclauncher.secondary"`** — pclauncher `0840e15`.
With the package-default affinity, `ActivityStarter` found display 0's existing home task and put
the new activity *there*:
```
ActivityTaskManager: DesktopModeLaunchParamsModifier: … task=Task{8a7e964 #9 type=home …}
VRI[SecondaryHomeActivity]: WindowInsets changed: 1920x1200 …        ← the panel, not the monitor
```
and `dumpsys activity` showed both activities stacked in task `#9` on display 0. Launcher3
solves the same collision from the other side (`taskAffinity=""` on its primary); a distinct
affinity on the secondary leaves the primary untouched.
Requirement: `pclauncher/docs/requirements/shell/secondary-home-task-affinity.md`.

**(3) `android.software.activities_on_secondary_displays`** — `5261945`, shipped like the
freeform feature file (`frameworks/native/data/etc/…xml` → `/vendor/etc/permissions/`).
`ActivityTaskManagerService.java:943` derives `mSupportsMultiDisplay` from it, and three refusals
hang off that boolean, all silent:

| gate | effect when the feature is absent |
|---|---|
| `RootWindowContainer.shouldPlaceSecondaryHomeOnDisplayArea` | no home on any non-default display |
| `ActivityTaskSupervisor.canPlaceEntityOnDisplay` | no activity may be placed there |
| `LaunchParamsUtil` | a launch aimed at display N is **redirected** to the default display |

The third row is why `am start --display 2 …` appeared to work and landed on display 0.
`adb shell pm has-feature android.software.activities_on_secondary_displays` said `false`; after
the fix, `true`, and the home task appeared on display 2 at the next boot.

---

## 4. What is present in the image but not yet exercised

- **Dragging a freeform window across the boundary** — `MultiDisplayVeiledResizeTaskPositioner`,
  the default desktop-mode positioner while `persist.wm.debug.desktop_veiled_resizing` (default
  true). `enable_cross_display_snap_support` is ENABLED.
- **`Meta+Ctrl+D`** — `KEY_GESTURE_TYPE_MOVE_TO_NEXT_DISPLAY`, registered unconditionally in
  `InputGestureManager`, handled by `DesktopTasksController.moveToNextDisplay` (cycles displays).
  The aconfig flag `move_to_external_display_shortcut=DISABLED` has no consumer in the tree.
  From adb: `dumpsys activity service SystemUIService WMShell desktopmode moveToNextDisplay <taskId>`.
- **Mirror (duplicate)** — Settings → Connected devices → display → Mirror (`Mirroring.kt`, backed
  by `Settings.Secure.MIRROR_BUILT_IN_DISPLAY`, live). Or `settings put secure mirror_built_in_display 1`.
- **Launcher menu items** — "Open on display N" is public API (`ActivityOptions.setLaunchDisplayId`,
  Stage A); "Move to display" for an existing window is WM-Shell-internal (Stage B, behind
  `platform/privileged/`).

---

## 5. How to verify, and the diagnostics that lie

```sh
adb shell pm has-feature android.software.activities_on_secondary_displays   # must be true
adb shell dumpsys activity activities | grep -E "Display #|SecondaryHome"    # SecondaryHome under Display #2
adb shell dumpsys SurfaceFlinger | grep "HWC display"                        # two physical displays
adb shell screencap -d <physical id from the line above> /data/local/tmp/m.png   # NOT the logical id
```

Two natural checks are **dead ends on an external display** and cost time here:

- **Pressing HOME on the monitor proves nothing.** `PhoneWindowManager.startDockOrHome` checks
  `TYPE_EXTERNAL` and emits `KEY_GESTURE_TYPE_REJECT_HOME_ON_EXTERNAL_DISPLAY` instead of starting
  home; the only log is "Attempting to move non-focused display N to top because a key is
  targeting it".
- **`am start … SECONDARY_HOME` is not the framework's home path.** It makes a `type=standard`
  task through the ordinary starter and never runs `canStartHomeOnDisplayArea`. Its one use: a
  `DesktopModeLaunchParamsModifier: … task=Task{#N type=home}` line means the launch was reused
  into an existing home task — the affinity collision's tell.

To re-run the framework's own home start without replugging, flip decorations off and on:
`settings put secure mirror_built_in_display 1`, then `0`. (`cmd display disable-display N` /
`enable-display N` does *not* re-run it — decorations stay true across it.)

---

## 6. Where the details live

- `pclauncher/docs/requirements/shell/secondary-display-home.md` — the chain, with file:line.
- `pclauncher/docs/requirements/shell/secondary-home-task-affinity.md` — the affinity finding.
- `device/pcx86/pc_x86_64/device.mk` — the feature file, with the on-device evidence in the comment.
- `claude-context/aosp-pc-x86_64/gotchas.md` — "A second display" and "part two".
