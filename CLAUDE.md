# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

**CLI tool (SPM):**
```bash
swift build                              # Build CLI
swift build -c release                   # Release build
.build/debug/macfan-cli status           # Read fans & temps (no sudo)
sudo .build/debug/macfan-cli max         # Full speed (needs sudo)
sudo .build/debug/macfan-cli auto        # Restore auto
```

**GUI app (XcodeGen + Xcode):**
```bash
xcodegen generate                        # Generate .xcodeproj from project.yml
xcodebuild -project MacFan.xcodeproj -scheme MacFan -configuration Debug build
xcodebuild -project MacFan.xcodeproj -scheme MacFan -configuration Release build
```

The generated `MacFan.xcodeproj` is not checked in — always regenerate from `project.yml`.

**Release (sign + notarize + publish):**
```bash
# 1. Build Release
xcodegen generate && xcodebuild -project MacFan.xcodeproj -scheme MacFan -configuration Release build

# 2. Install to /Applications
cp -R "$(xcodebuild -project MacFan.xcodeproj -scheme MacFan -configuration Release -showBuildSettings | grep ' BUILT_PRODUCTS_DIR' | awk '{print $3}')/MacFan.app" /Applications/

# 3. Sign with Developer ID (all binaries)
IDENTITY="Developer ID Application: saikun sun (2FJFJ2WAF8)"
for bin in /Applications/MacFan.app/Contents/MacOS/MacFanHelper /Applications/MacFan.app/Contents/Resources/MacFanHelper; do
    [ -f "$bin" ] && codesign --force --sign "$IDENTITY" --options runtime --timestamp "$bin"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp /Applications/MacFan.app

# 4. Create DMG, notarize, staple
STAGING=$(mktemp -d) && cp -R /Applications/MacFan.app "$STAGING/" && ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "MacFan" -srcfolder "$STAGING" -ov -format UDZO output.dmg && rm -rf "$STAGING"
xcrun notarytool submit output.dmg --keychain-profile "notary" --wait
xcrun stapler staple output.dmg

# 5. Publish
gh release create vX.X.X output.dmg --title "MacFan vX.X.X" --notes "..."
```

**Helper reinstall (after binary changes):**
```bash
# Use AppleScript for admin privileges:
osascript -e 'do shell script "launchctl bootout system/com.macfan.helper 2>/dev/null; cp /Applications/MacFan.app/Contents/MacOS/MacFanHelper /Library/PrivilegedHelperTools/com.macfan.helper; chmod 755 /Library/PrivilegedHelperTools/com.macfan.helper; launchctl bootstrap system /Library/LaunchDaemons/com.macfan.helper.plist" with administrator privileges'
```

## Architecture

Three-tier privilege separation:

```
MacFan.app (user) ──XPC──▶ MacFanHelper (root daemon) ──IOKit──▶ SMC hardware
     │                           │
     │ SMC reads (no root)       │ SMC writes (root required)
     ▼                           ▼
  FanMonitor                  SMCWriter
```

- **SMC reads** (temperature, fan RPM) work without root — the main app reads directly via IOKit.
- **SMC writes** (set fan speed) require root — done through XPC to the privileged helper daemon.
- The helper installs once to `/Library/PrivilegedHelperTools/com.macfan.helper` with a LaunchDaemon plist. After that, no more password prompts.

## Key Technical Details

### M5 Pro SMC Key Naming (Critical)
M5 Pro uses **lowercase** `F0md` for fan mode, not the documented uppercase `F0Md`. The `Ftst` (force test) key does **not exist** on M5 Pro. Code detects both variants at runtime via `detectModeKey()`. SMCWriter caches Ftst availability in `ftstAvailable` to avoid repeated IOKit queries.

### SMCKeyData Struct Layout
Must exactly match the kernel's `SMCParamStruct`. The critical detail is the `padding: UInt16` field between `keyInfo` and `result`, and `keyInfo.dataSize` must be `UInt32` (not `IOByteCount` which is 8 bytes on 64-bit). Total struct size: **80 bytes**.

### Fan Control Sequence (Apple Silicon)
```
1. Write F{id}md = 1 (manual mode, retry up to 200×, 50ms apart)
2. Write F{id}Tg = target RPM (flt type, retry up to 200×)
3. To restore: write F{id}md = 0
```
If target speed write fails, always restore F{id}md = 0 to avoid leaving fan in manual mode at wrong speed.

### Temperature Sensor Discovery
On M5 Pro, many traditional CPU temperature keys (Tc0P, Tc0D, etc.) **exist but return 0.0°C**. The `discoverSensors()` method filters with `temp > 0` (not `>= 0`) to exclude these phantom readings.

### Data Types on M5 Pro
All values use `flt` (IEEE 754 float, little-endian). Older Macs may use `sp78` (temps) or `fpe2` (fan RPM) — the code handles all types automatically via `readTemperature()` and `readFanSpeed()`.

## Source Layout

| Directory | Target | Description |
|-----------|--------|-------------|
| `Sources/MacFanCore/` | Shared library | SMCKit, DataTypes, SMCKeys, FanMonitor, FanProfile, BatteryService, HelperProtocol |
| `Sources/MacFanApp/` | GUI app (MenuBarExtra) | MenuBarView, Components (shared styles), HelperInstaller/HelperController, SettingsView, ProfileEditView/ProfileEditorController |
| `Sources/MacFanHelper/` | Root daemon | XPC listener (HelperDelegate), SMCWriter (fan control with retry logic) |
| `Sources/macfan-cli/` | CLI tool | ArgumentParser commands: status/list/set/max/auto/debug |

### MacFanCore Module Sharing (Important)
MacFanCore is shared differently between build systems:
- **SPM**: imported as a library dependency (`import MacFanCore` in CLI)
- **XcodeGen**: compiled directly into both app and helper targets as same-module sources — **no `import MacFanCore`** in Xcode targets

This means `@MainActor` annotations in MacFanCore work correctly in the app but are ignored in the helper daemon context.

## Concurrency Model

- **GUI layer**: `@MainActor` on `FanMonitor`, `ProfileManager`. All UI state mutations are main-thread-safe.
- **XPC callbacks**: Bridged to MainActor via `Task { @MainActor in }` pattern.
- **SMCKit**: Uses `NSLock` for thread-safe `open()`/`close()` — marked `@unchecked Sendable`.
- **FanControlEngine**: Uses one shared `NSLock`-serialized engine in the helper so all XPC clients coordinate writes to global SMC state. CLI reuses the same control and rollback logic.
- **Data structs** (`FanInfo`, `TempInfo`, `BatteryInfo`, `FanProfile`): All `Sendable`.

## XPC Protocol

Defined in `HelperProtocol.swift`, Mach service name: `com.macfan.helper`
```swift
@objc protocol HelperProtocol {
    func setFanSpeed(fanID: Int, rpm: Double, withReply: @escaping (Bool, String) -> Void)
    func resetFan(fanID: Int, withReply: @escaping (Bool, String) -> Void)
    func setAllFans(percent: Double, withReply: @escaping (Bool, String) -> Void)
    func setAllFansMax(withReply: @escaping (Bool, String) -> Void)
    func resetAllFans(withReply: @escaping (Bool, String) -> Void)
    func ping(withReply: @escaping (Bool) -> Void)
}
```

XPC security: `HelperDelegate` validates the Apple signing chain, team ID (`2FJFJ2WAF8`), and app identifier (`com.macfan.MacFan`) before accepting connections.

## Helper Installation Flow

1. `HelperInstaller.findHelperBinary()` locates `MacFanHelper` in app bundle's `Contents/MacOS/`
2. Writes a shell script to temp file (UUID in filename to avoid races)
3. Invokes via `NSAppleScript` with `administrator privileges` (one password prompt, main thread only)
4. Script boots out the old daemon **before** replacing the binary (overwriting a running signed executable gets it killed), copies it to `/Library/PrivilegedHelperTools/`, writes the plist to `/Library/LaunchDaemons/`, then retries `launchctl bootstrap` a few times (bootout is asynchronous)

`HelperInstaller.currentStatus()` spawns `launchctl` and compares binaries, so it must run off the main thread — `HelperController.refresh()` does this. Never call it from a view initializer or `@State` default value (views are re-initialized on every monitor update).

**Important**: After rebuilding the helper binary, the installed copy at `/Library/PrivilegedHelperTools/` must be updated and the daemon restarted. The app shows Install/Update Helper when the service is absent or the installed binary differs from the bundled helper. The helper exits on SIGTERM via `exit()` — `RunLoop.run()` restarts after `CFRunLoopStop`, so stopping the run loop does not end the process.

## Code Signing

- Team ID: `2FJFJ2WAF8`
- Development: `Apple Development` (automatic signing)
- Distribution: `Developer ID Application: saikun sun (2FJFJ2WAF8)` with `--options runtime --timestamp`
- Post-build script in project.yml embeds MacFanHelper into `Contents/MacOS/` and re-signs it
- Notarization credentials stored as keychain profile `"notary"` for `xcrun notarytool`
- **Both** `Contents/MacOS/MacFanHelper` and `Contents/Resources/MacFanHelper` must be signed for notarization

## GUI Structure

The app uses `MenuBarExtra` with `.window` style. The panel is a Chinese, always-dark dashboard (warm radial background, cards in `Components.swift`: `DashCard`, `Chip`, `BigValue`, `BarSparkline`/`AreaSparkline`, `RingGauge`, `SegmentButton`). Layout: hero (max temp + status word + chips) → fan card → temperature cards (2-column grid, battery temps go into the battery card) → battery card → profiles card. Key UI components:
- **FanMonitor.controlMode** (`.system` / `.manual(percent)` / `.profile(percent?)`): single source of truth for what the UI shows. Views never keep their own manual/auto flags.
- **FanControls**: One control for all fans — segments 自动 / 安静 25% / 均衡 50% / 降温 75% / 强冷 100% plus a custom slider (applies on release). Do not use `Slider(step:)`; macOS draws a tick per step.
- **FanMonitor.history** (`MonitorHistory`): last 60 samples of average fan RPM and per-category max temperature, used by the sparklines.
- **ProfileRow**: Whole row toggles activation; ⋯ menu / context menu for Edit, Duplicate, Delete (delete offers Undo instead of a confirmation dialog).
- **ProfileEditorController**: Opens `ProfileEditView` in a floating NSPanel. New profiles are only added on Create. Saving calls `makeFirstResponder(nil)` first so a focused number field commits its value.
- **TemperatureCard**: One card per sensor category showing the hottest reading and its trend; tapping opens a popover with every sensor in the category.
- **Menu bar label**: Rendered to a template `NSImage` via `ImageRenderer` (`MenuBarIcon`) — a `Label`/`HStack` label does not reliably show both icon and text.

### Fan control ownership (FanMonitor)
`manualOwner` records who put the hardware into manual mode:
- `.user` (slider/presets) — kept until the user picks Auto or a profile. Picking a speed deactivates the active profile.
- `.profile` — restored to auto when the active profile stops matching or is deactivated.
- Each refresh reads `F{id}md` and reconciles: all fans back to auto clears the owner (and re-applies an active profile); manual mode the app didn't set (CLI, crash leftovers) is adopted.
- Profile requests are not started while a user request is in flight; stale completions are ignored via generation counters.

## Profile System

Profiles persist to `~/Library/Application Support/MacFan/profiles.json`. Rules are evaluated every 2s: sorted by temp threshold descending, first matching rule (temp ≥ threshold) determines fan speed %. Includes 3°C hysteresis to prevent oscillation near thresholds. Conditions: Always / Charging / OnBattery / BatteryBelow(X%). Activation (the row checkmark) is the only on/off switch; the editor always saves `isEnabled = true`.
