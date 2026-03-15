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

**Release DMG:**
```bash
# After Release build:
hdiutil create -volname "MacFan" -srcfolder <dir-with-app-and-Applications-symlink> -ov -format UDZO output.dmg
gh release create vX.X.X output.dmg --title "MacFan vX.X.X" --notes "..."
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
M5 Pro uses **lowercase** `F0md` for fan mode, not the documented uppercase `F0Md`. The `Ftst` (force test) key does **not exist** on M5 Pro. Code detects both variants at runtime via `detectModeKey()`. Always check key existence before writing.

### SMCKeyData Struct Layout
Must exactly match the kernel's `SMCParamStruct`. The critical detail is the `padding: UInt16` field between `keyInfo` and `result`, and `keyInfo.dataSize` must be `UInt32` (not `IOByteCount` which is 8 bytes on 64-bit). Total struct size: **80 bytes**.

### Fan Control Sequence (Apple Silicon)
```
1. Write F{id}md = 1 (manual mode, retry up to 200×, 50ms apart)
2. Write F{id}Tg = target RPM (flt type, retry up to 200×)
3. To restore: write F{id}md = 0
```
If target speed write fails, always restore F{id}md = 0 to avoid leaving fan in manual mode at wrong speed.

### Data Types on M5 Pro
All values use `flt` (IEEE 754 float, little-endian). Older Macs may use `sp78` (temps) or `fpe2` (fan RPM) — the code handles all types automatically via `readTemperature()` and `readFanSpeed()`.

## Source Layout

| Directory | Target | Description |
|-----------|--------|-------------|
| `Sources/MacFanCore/` | Shared library | SMCKit, DataTypes, SMCKeys, FanMonitor, FanProfile, BatteryService, HelperProtocol |
| `Sources/MacFanApp/` | GUI app (MenuBarExtra) | SwiftUI views, HelperInstaller, HelperManager, Settings |
| `Sources/MacFanHelper/` | Root daemon | XPC listener, SMCWriter (fan control with retry logic) |
| `Sources/macfan-cli/` | CLI tool | ArgumentParser commands: status/list/set/max/auto/debug |

### MacFanCore Module Sharing (Important)
MacFanCore is shared differently between build systems:
- **SPM**: imported as a library dependency (`import MacFanCore` in CLI)
- **XcodeGen**: compiled directly into both app and helper targets as same-module sources — **no `import MacFanCore`** in Xcode targets

This means `@MainActor` annotations in MacFanCore work correctly in the app but are ignored in the helper daemon context.

## Concurrency Model

- **GUI layer**: `@MainActor` on `FanMonitor`, `ProfileManager`, `HelperManager`. All UI state mutations are main-thread-safe.
- **XPC callbacks**: Bridged to MainActor via `Task { @MainActor in }` pattern.
- **SMCKit**: Uses `NSLock` for thread-safe `open()`/`close()` — marked `@unchecked Sendable`.
- **SMCWriter** (helper): Uses `NSLock` to serialize all fan control operations. Each XPC client gets its own SMCWriter instance.
- **Data structs** (`FanInfo`, `TempInfo`, `BatteryInfo`, `FanProfile`): All `Sendable`.

## XPC Protocol

Defined in `HelperProtocol.swift`, Mach service name: `com.macfan.helper`
```swift
@objc protocol HelperProtocol {
    func setFanSpeed(fanID: Int, rpm: Double, withReply: @escaping (Bool, String) -> Void)
    func setAllFansMax(withReply: @escaping (Bool, String) -> Void)
    func resetAllFans(withReply: @escaping (Bool, String) -> Void)
    func ping(withReply: @escaping (Bool) -> Void)
}
```

XPC security: `HelperDelegate` validates the caller's code signature team ID (`2FJFJ2WAF8`) before accepting connections.

## Helper Installation Flow

1. `HelperInstaller.findHelperBinary()` locates `MacFanHelper` in app bundle's `Contents/MacOS/`
2. Writes a shell script to temp file (UUID in filename to avoid races)
3. Invokes via `NSAppleScript` with `administrator privileges` (one password prompt)
4. Script copies binary to `/Library/PrivilegedHelperTools/`, writes plist to `/Library/LaunchDaemons/`, bootstraps via `launchctl`

## Code Signing

- Team ID: `2FJFJ2WAF8`
- Identity: `Apple Development`
- Post-build script in project.yml embeds MacFanHelper into `Contents/MacOS/` and re-signs it
- The helper binary in `/Library/PrivilegedHelperTools/` must also be signed

## Profile System

Profiles persist to `~/Library/Application Support/MacFan/profiles.json`. Rules are evaluated every 2s: sorted by temp threshold descending, first matching rule (temp ≥ threshold) determines fan speed %. Includes 3°C hysteresis to prevent oscillation near thresholds. Conditions: Always / Charging / OnBattery / BatteryBelow(X%).
