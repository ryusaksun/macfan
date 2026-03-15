import ArgumentParser
import Foundation
import MacFanCore

@main
struct MacFanCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macfan-cli",
        abstract: "macOS 风扇控制工具 (Apple Silicon)",
        version: "0.1.0",
        subcommands: [
            Status.self,
            List.self,
            Set.self,
            Max.self,
            Auto.self,
            Debug.self,
        ],
        defaultSubcommand: Status.self
    )
}

// MARK: - Status 命令

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "显示当前风扇转速和温度"
    )

    func run() throws {
        let smc = SMCKit()
        try smc.open()
        defer { smc.close() }

        // 读取风扇信息
        let fanCount: Int
        do {
            fanCount = Int(try smc.readUInt8(SMCKeys.fanCount))
        } catch {
            fanCount = 0
        }

        print("🌀 风扇状态")
        print(String(repeating: "─", count: 50))

        if fanCount == 0 {
            print("  未检测到风扇")
        } else {
            for i in 0..<fanCount {
                let actual = try smc.readFanSpeed(SMCKeys.fanActualSpeed(i))
                let min = try smc.readFanSpeed(SMCKeys.fanMinSpeed(i))
                let max = try smc.readFanSpeed(SMCKeys.fanMaxSpeed(i))

                let mode: String
                do {
                    let modeVal = try smc.readUInt8(SMCKeys.fanMode(i))
                    switch modeVal {
                    case 0: mode = "自动"
                    case 1: mode = "手动"
                    case 3: mode = "系统"
                    default: mode = "未知(\(modeVal))"
                    }
                } catch {
                    mode = "未知"
                }

                let percent: Double
                if actual <= 0 {
                    percent = 0
                } else if max > min {
                    percent = Swift.max(0, Swift.min(100, (actual - min) / (max - min) * 100))
                } else {
                    percent = 0
                }
                let bar = makeProgressBar(percent: percent, width: 20)

                let rpmStr = actual > 0 ? "\(String(format: "%.0f", actual)) RPM" : "停转"
                print("  风扇 \(i): \(rpmStr.padding(toLength: 10, withPad: " ", startingAt: 0)) [\(bar)] \(String(format: "%.0f%%", percent))  (\(mode))")
                print("          范围: \(String(format: "%.0f", min)) - \(String(format: "%.0f", max)) RPM")
            }
        }

        // 读取温度
        print()
        print("🌡️ 温度传感器")
        print(String(repeating: "─", count: 50))

        var foundAny = false
        for (key, name) in SMCKeys.temperatureKeys {
            do {
                let temp = try smc.readTemperature(key)
                if temp > 0 && temp < 130 {
                    let indicator = tempIndicator(temp)
                    print("  \(indicator) \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(String(format: "%6.1f °C", temp))")
                    foundAny = true
                }
            } catch {
                // key 不存在，跳过
                continue
            }
        }

        if !foundAny {
            print("  未检测到温度传感器")
        }
    }
}

// MARK: - List 命令

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "列出所有风扇和温度传感器"
    )

    @Flag(name: .shortAndLong, help: "显示详细信息（包括 SMC key 和数据类型）")
    var verbose = false

    func run() throws {
        let smc = SMCKit()
        try smc.open()
        defer { smc.close() }

        // 风扇列表
        let fanCount: Int
        do {
            fanCount = Int(try smc.readUInt8(SMCKeys.fanCount))
        } catch {
            fanCount = 0
        }

        print("🌀 风扇列表 (共 \(fanCount) 个)")
        print(String(repeating: "─", count: 50))

        for i in 0..<fanCount {
            print("  风扇 \(i):")

            let keys = [
                (SMCKeys.fanActualSpeed(i), "实际转速"),
                (SMCKeys.fanMinSpeed(i), "最小转速"),
                (SMCKeys.fanMaxSpeed(i), "最大转速"),
                (SMCKeys.fanTargetSpeed(i), "目标转速"),
                (SMCKeys.fanMode(i), "控制模式"),
            ]

            for (key, label) in keys {
                do {
                    let val = try smc.readKey(key)
                    let typeStr = val.dataType.toString
                    let formatted = DataTypes.formatValue(bytes: val.bytes, dataType: val.dataType, dataSize: val.dataSize)

                    if verbose {
                        print("    \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(formatted.padding(toLength: 12, withPad: " ", startingAt: 0))  [key=\(key), type=\(typeStr), size=\(val.dataSize)]")
                    } else {
                        print("    \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(formatted)")
                    }
                } catch {
                    if verbose {
                        print("    \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) N/A  [key=\(key)]")
                    }
                }
            }
        }

        // 温度传感器列表
        print()
        print("🌡️ 可用温度传感器")
        print(String(repeating: "─", count: 50))

        var count = 0
        for (key, name) in SMCKeys.temperatureKeys {
            do {
                let val = try smc.readKey(key)
                let temp = try smc.readTemperature(key)
                if temp > 0 && temp < 130 {
                    let typeStr = val.dataType.toString

                    if verbose {
                        print("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(String(format: "%6.1f °C", temp))  [key=\(key), type=\(typeStr)]")
                    } else {
                        print("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(String(format: "%6.1f °C", temp))")
                    }
                    count += 1
                }
            } catch {
                continue
            }
        }

        print()
        print("共发现 \(count) 个温度传感器")
    }
}

// MARK: - Set 命令

struct Set: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "设置指定风扇的目标转速"
    )

    @Argument(help: "风扇 ID (0, 1, ...)")
    var fanID: Int

    @Argument(help: "目标转速 (RPM)")
    var rpm: Int

    func run() throws {
        let smc = SMCKit()
        try smc.open()
        defer { smc.close() }

        let fanCount = Int(try smc.readUInt8(SMCKeys.fanCount))
        guard fanID >= 0 && fanID < fanCount else {
            print("❌ 无效的风扇 ID: \(fanID) (共 \(fanCount) 个风扇)")
            throw ExitCode.failure
        }

        // 读取转速范围
        let minRPM = try smc.readFanSpeed(SMCKeys.fanMinSpeed(fanID))
        let maxRPM = try smc.readFanSpeed(SMCKeys.fanMaxSpeed(fanID))

        guard Double(rpm) >= minRPM && Double(rpm) <= maxRPM else {
            print("❌ 转速超出范围: \(rpm) RPM (范围: \(String(format: "%.0f", minRPM)) - \(String(format: "%.0f", maxRPM)))")
            throw ExitCode.failure
        }

        print("设置风扇 \(fanID) 转速为 \(rpm) RPM...")

        try setFanSpeed(smc: smc, fanID: fanID, targetRPM: Double(rpm))

        let actual = try smc.readFanSpeed(SMCKeys.fanActualSpeed(fanID))
        print("✅ 设置完成！当前转速: \(String(format: "%.0f", actual)) RPM")
        print("⚠️  注意: 使用 'macfan-cli auto' 恢复自动控制")
    }
}

// MARK: - Max 命令

struct Max: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "所有风扇全速运行"
    )

    func run() throws {
        let smc = SMCKit()
        try smc.open()
        defer { smc.close() }

        let fanCount = Int(try smc.readUInt8(SMCKeys.fanCount))

        guard fanCount > 0 else {
            print("❌ 未检测到风扇")
            throw ExitCode.failure
        }

        print("🚀 全速模式: 将 \(fanCount) 个风扇设置为最大转速...")

        for i in 0..<fanCount {
            let maxRPM = try smc.readFanSpeed(SMCKeys.fanMaxSpeed(i))
            print("  风扇 \(i): → \(String(format: "%.0f", maxRPM)) RPM")
            try setFanSpeed(smc: smc, fanID: i, targetRPM: maxRPM)
        }

        print()
        print("✅ 全速模式已启用！")
        print("⚠️  使用 'macfan-cli auto' 恢复自动控制")
    }
}

// MARK: - Auto 命令

struct Auto: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "恢复所有风扇为自动控制"
    )

    func run() throws {
        let smc = SMCKit()
        try smc.open()
        defer { smc.close() }

        let fanCount = Int(try smc.readUInt8(SMCKeys.fanCount))

        print("恢复自动控制...")

        // 关闭 Force/Test 模式（仅当 Ftst 存在时）
        let ftstInfo = try? smc.getKeyInfo(key: FourCharCode(fromString: SMCKeys.forceMode))
        if let info = ftstInfo, info.dataSize > 0 {
            do {
                try smc.writeUInt8(SMCKeys.forceMode, value: 0)
                print("  ✓ 已关闭 Force 模式 (Ftst=0)")
            } catch {
                print("  ⚠ 关闭 Force 模式失败: \(error)")
            }
        }

        // 将每个风扇设回自动模式 (尝试小写和大写键名)
        for i in 0..<fanCount {
            var restored = false
            for modeKey in [SMCKeys.fanMode(i), SMCKeys.fanModeLegacy(i)] {
                do {
                    let info = try smc.getKeyInfo(key: FourCharCode(fromString: modeKey))
                    guard info.dataSize > 0 else { continue }
                    try smc.writeUInt8(modeKey, value: 0)
                    print("  ✓ 风扇 \(i) 已恢复自动模式 (\(modeKey)=0)")
                    restored = true
                    break
                } catch {
                    continue
                }
            }
            if !restored {
                print("  ⚠ 风扇 \(i) 恢复失败: 未找到模式键")
            }
        }

        // 等待一下再读取
        Thread.sleep(forTimeInterval: 1.0)

        // 显示当前状态
        for i in 0..<fanCount {
            let actual = try smc.readFanSpeed(SMCKeys.fanActualSpeed(i))
            print("  风扇 \(i): \(String(format: "%.0f", actual)) RPM")
        }

        print()
        print("✅ 已恢复自动控制")
    }
}

// MARK: - Apple Silicon 风扇控制

/// M5 Pro 风扇控制流程：
/// 1. 写 F{id}md=1 切换手动模式
/// 2. 写 F{id}Tg=目标RPM
/// 恢复: 写 F{id}md=0
func setFanSpeed(smc: SMCKit, fanID: Int, targetRPM: Double) throws {
    // Step 1: 检测模式键 (F0md 小写 vs F0Md 大写)
    let modeKey: String
    let modeKeyInfo = try? smc.getKeyInfo(key: FourCharCode(fromString: SMCKeys.fanMode(fanID)))
    let legacyKeyInfo = try? smc.getKeyInfo(key: FourCharCode(fromString: SMCKeys.fanModeLegacy(fanID)))

    if let info = modeKeyInfo, info.dataSize > 0 {
        modeKey = SMCKeys.fanMode(fanID)
    } else if let info = legacyKeyInfo, info.dataSize > 0 {
        modeKey = SMCKeys.fanModeLegacy(fanID)
    } else {
        print("  ❌ 未找到风扇模式键 (F\(fanID)md / F\(fanID)Md)")
        throw ExitCode.failure
    }

    // Step 2: 尝试 Ftst (旧款需要，新款可跳过)
    let ftstInfo = try? smc.getKeyInfo(key: FourCharCode(fromString: SMCKeys.forceMode))
    if let info = ftstInfo, info.dataSize > 0 {
        print("  ⏳ 启用 Force 模式 (Ftst=1)...")
        try? smc.writeUInt8(SMCKeys.forceMode, value: 1)
        Thread.sleep(forTimeInterval: 3.0)
    }

    // Step 3: 切换手动模式 (重试)
    print("  ⏳ 切换手动模式 (\(modeKey)=1)...")
    var manualSet = false
    for attempt in 1...200 {
        do {
            try smc.writeUInt8(modeKey, value: 1)
            let mode = try smc.readUInt8(modeKey)
            if mode == 1 {
                print("  ✓ 手动模式已启用 (尝试 \(attempt) 次)")
                manualSet = true
                break
            }
        } catch {
            // 继续重试
        }
        usleep(50_000) // 50ms
    }

    guard manualSet else {
        print("  ❌ 无法切换到手动模式 (200 次重试后放弃)")
        throw ExitCode.failure
    }

    // Step 4: 设置目标转速 (重试)
    print("  ⏳ 设置目标转速 (F\(fanID)Tg=\(String(format: "%.0f", targetRPM)))...")
    var targetSet = false
    for attempt in 1...200 {
        do {
            try smc.writeFanSpeed(SMCKeys.fanTargetSpeed(fanID), rpm: targetRPM)
            let readBack = try smc.readFanSpeed(SMCKeys.fanTargetSpeed(fanID))
            if abs(readBack - targetRPM) < 100 {
                print("  ✓ 目标转速已设置 (尝试 \(attempt) 次)")
                targetSet = true
                break
            }
        } catch {
            // 继续重试
        }
        usleep(50_000) // 50ms
    }

    guard targetSet else {
        // 恢复自动
        try? smc.writeUInt8(modeKey, value: 0)
        print("  ❌ 无法设置目标转速 (200 次重试后放弃)")
        throw ExitCode.failure
    }
}

// MARK: - Debug 命令

struct Debug: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "调试 SMC 读写（诊断问题用）"
    )

    @Flag(name: .shortAndLong, help: "扫描所有 SMC 键（较慢）")
    var scan = false

    func run() throws {
        let smc = SMCKit()
        try smc.open()
        defer { smc.close() }

        print("📋 MacFan CLI Debug")
        print()

        // 1. 读取基本信息
        print("── 风扇基础信息 ──")
        let fanCount = Int(try smc.readUInt8(SMCKeys.fanCount))
        print("  FNum (风扇数): \(fanCount)")

        for i in 0..<fanCount {
            let actual = try smc.readFanSpeed(SMCKeys.fanActualSpeed(i))
            let min = try smc.readFanSpeed(SMCKeys.fanMinSpeed(i))
            let max = try smc.readFanSpeed(SMCKeys.fanMaxSpeed(i))
            let target = try smc.readFanSpeed(SMCKeys.fanTargetSpeed(i))
            print("  F\(i): actual=\(actual) target=\(target) min=\(min) max=\(max)")
        }

        // 2. 探测所有可能的风扇控制键
        print()
        print("── 风扇控制键探测 ──")
        let controlKeys = [
            "Ftst", "FNum",
            "FS! ", "FS!!", "F0Sf",
            "F0Ac", "F0Mn", "F0Mx", "F0Tg", "F0Md",
            "F0Ct", "F0ID", "F0Dc", "F0Lm",
            "F1Ac", "F1Mn", "F1Mx", "F1Tg", "F1Md",
            "F1Ct", "F1ID", "F1Dc", "F1Lm",
        ]
        for key in controlKeys {
            do {
                let info = try smc.getKeyInfo(key: FourCharCode(fromString: key))
                if info.dataSize > 0 {
                    let val = try smc.readKey(key)
                    let hex = val.bytes.prefix(Int(val.dataSize)).map { String(format: "%02x", $0) }.joined(separator: " ")
                    let formatted = DataTypes.formatValue(bytes: val.bytes, dataType: val.dataType, dataSize: val.dataSize)
                    print("  ✅ \(key): type=\(val.dataType.toString) size=\(val.dataSize) value=\(formatted) raw=[\(hex)]")
                } else {
                    print("  ❌ \(key): size=0 (不存在或不可读)")
                }
            } catch {
                print("  ❌ \(key): \(error)")
            }
        }

        // 3. 写入测试
        print()
        print("── 写入测试 ──")

        // 测试写入 Ftst
        let ftstResult = smc.writeKeyDebug(SMCKeys.forceMode, dataType: FourCharCode(fromString: "ui8 "), bytes: [1])
        print("  Ftst=1: ioResult=\(ftstResult.ioResult) smcResult=\(ftstResult.smcResult) (\(ftstResult.smcResult == 0 ? "成功" : "失败 0x\(String(ftstResult.smcResult, radix: 16))"))")

        // 测试写入 F0Tg (little-endian float)
        if fanCount > 0 {
            let maxRPM = try smc.readFanSpeed(SMCKeys.fanMaxSpeed(0))
            let leBytes = DataTypes.encodeFloat(Float(maxRPM))
            let leHex = leBytes.map { String(format: "%02x", $0) }.joined(separator: " ")

            let tgResultLE = smc.writeKeyDebug(SMCKeys.fanTargetSpeed(0), dataType: FourCharCode(fromString: "flt "), bytes: leBytes)
            print("  F0Tg=\(maxRPM) (LE [\(leHex)]): ioResult=\(tgResultLE.ioResult) smcResult=\(tgResultLE.smcResult)")

            // 立即读回
            let readBack1 = try smc.readFanSpeed(SMCKeys.fanTargetSpeed(0))
            print("  F0Tg 读回: \(readBack1)")

            // 测试大端序写入
            let beBytes = [leBytes[3], leBytes[2], leBytes[1], leBytes[0]]
            let beHex = beBytes.map { String(format: "%02x", $0) }.joined(separator: " ")

            let tgResultBE = smc.writeKeyDebug(SMCKeys.fanTargetSpeed(0), dataType: FourCharCode(fromString: "flt "), bytes: beBytes)
            print("  F0Tg=\(maxRPM) (BE [\(beHex)]): ioResult=\(tgResultBE.ioResult) smcResult=\(tgResultBE.smcResult)")

            let readBack2 = try smc.readFanSpeed(SMCKeys.fanTargetSpeed(0))
            print("  F0Tg 读回: \(readBack2)")

            // 恢复
            _ = smc.writeKeyDebug(SMCKeys.forceMode, dataType: FourCharCode(fromString: "ui8 "), bytes: [0])
        }

        // 4. 扫描所有 SMC 键 (寻找风扇相关)
        if scan {
            print()
            print("── 扫描所有 SMC 键 (F 开头) ──")
            do {
                let totalVal = try smc.readKey("#KEY")
                let totalKeys = Int(DataTypes.decodeUInt32(totalVal.bytes))
                print("  SMC 共有 \(totalKeys) 个键")

                for idx in 0..<UInt32(totalKeys) {
                    do {
                        let keyCode = try smc.getKeyAtIndex(idx)
                        let keyStr = keyCode.toString

                        // 只显示 F 开头的键（风扇相关）
                        if keyStr.hasPrefix("F") {
                            let info = try smc.getKeyInfo(key: keyCode)
                            if info.dataSize > 0 {
                                let val = try smc.readKey(keyStr)
                                let hex = val.bytes.prefix(Int(val.dataSize)).map { String(format: "%02x", $0) }.joined(separator: " ")
                                let formatted = DataTypes.formatValue(bytes: val.bytes, dataType: val.dataType, dataSize: val.dataSize)
                                print("  \(keyStr): type=\(val.dataType.toString) size=\(val.dataSize) value=\(formatted) raw=[\(hex)]")
                            } else {
                                print("  \(keyStr): size=0")
                            }
                        }
                    } catch {
                        continue
                    }
                }
            } catch {
                print("  ⚠ 无法读取 #KEY: \(error)")
            }
        } else {
            print()
            print("💡 使用 'macfan-cli debug --scan' 扫描所有 SMC 键")
        }
    }
}

// MARK: - 辅助函数

/// 生成进度条
func makeProgressBar(percent: Double, width: Int) -> String {
    let clamped = max(0, min(100, percent))
    let filled = Int(clamped / 100.0 * Double(width))
    let empty = width - filled
    return String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
}

/// 温度指示符
func tempIndicator(_ temp: Double) -> String {
    switch temp {
    case ..<40: return "🟢"
    case ..<60: return "🟡"
    case ..<80: return "🟠"
    default: return "🔴"
    }
}
