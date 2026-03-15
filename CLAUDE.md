# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

**CLI tool (SPM):**
```bash
swift build                              # Build CLI
.build/debug/macfan-cli status           # Read fans & temps (no sudo)
sudo .build/debug/macfan-cli max         # Full speed (needs sudo)
sudo .build/debug/macfan-cli auto        # Restore auto
```

**GUI app (XcodeGen + Xcode):**
```bash
xcodegen generate                        # Generate .xcodeproj from project.yml
xcodebuild -project MacFan.xcodeproj -scheme MacFan -configuration Debug build
```

The generated `MacFan.xcodeproj` is not checked in — always regenerate from `project.yml`.

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
M5 Pro uses **lowercase** `F0md` for fan mode, not the documented uppercase `F0Md`. The `Ftst` (force test) key does **not exist** on M5 Pro. Code detects both variants at runtime via `detectModeKey()`.

### SMCKeyData Struct Layout
Must exactly match the kernel's `SMCParamStruct`. The critical detail is the `padding: UInt16` field between `keyInfo` and `result`, and `keyInfo.dataSize` must be `UInt32` (not `IOByteCount` which is 8 bytes on 64-bit). Total struct size: **80 bytes**.

### Fan Control Sequence (Apple Silicon)
```
1. Write F{id}md = 1 (manual mode, retry up to 200×, 50ms apart)
2. Write F{id}Tg = target RPM (flt type, retry up to 200×)
3. To restore: write F{id}md = 0
```

### Data Types on M5 Pro
All values use `flt` (IEEE 754 float, little-endian). Older Macs may use `sp78` (temps) or `fpe2` (fan RPM) — the code handles all types automatically.

## Source Layout

| Directory | Target | Description |
|-----------|--------|-------------|
| `Sources/MacFanCore/` | Shared library | SMCKit, DataTypes, SMCKeys, FanMonitor, FanProfile, BatteryService, HelperProtocol |
| `Sources/MacFanApp/` | GUI app (MenuBarExtra) | SwiftUI views, HelperInstaller, Settings |
| `Sources/MacFanHelper/` | Root daemon | XPC listener, SMCWriter (fan control with retry logic) |
| `Sources/macfan-cli/` | CLI tool | ArgumentParser commands: status/list/set/max/auto/debug |

MacFanCore is shared: SPM uses it as a library target; XcodeGen compiles it directly into both the app and helper targets (no `import MacFanCore` in Xcode targets — same module).

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

## Code Signing

- Team ID: `2FJFJ2WAF8`
- Identity: `Apple Development`
- Post-build script in project.yml embeds MacFanHelper into `Contents/MacOS/` and re-signs it
- The helper binary in `/Library/PrivilegedHelperTools/` must also be signed

## Profile System

Profiles persist to `~/Library/Application Support/MacFan/profiles.json`. Rules are evaluated every 2s: sorted by temp threshold descending, first matching rule (temp ≥ threshold) determines fan speed %. Conditions: Always / Charging / OnBattery / BatteryBelow(X%).
