import Foundation

/// SMC 写操作实现 (以 root 权限运行)
final class SMCWriter: NSObject, HelperProtocol {
    private let smc = SMCKit()
    private var isOpen = false
    private let lock = NSLock()
    private var ftstAvailable: Bool?

    private func ensureOpen() throws {
        if !isOpen {
            try smc.open()
            isOpen = true
        }
    }

    /// 检测 Ftst 键是否存在（缓存结果）
    private func isFtstAvailable() -> Bool {
        if let cached = ftstAvailable { return cached }
        let available: Bool
        if let info = try? smc.getKeyInfo(key: FourCharCode(fromString: SMCKeys.forceMode)),
           info.dataSize > 0 {
            available = true
        } else {
            available = false
        }
        ftstAvailable = available
        return available
    }

    /// 检测可用的模式键 (F0md 小写 vs F0Md 大写)
    private func detectModeKey(fanID: Int) -> String? {
        for key in [SMCKeys.fanMode(fanID), SMCKeys.fanModeLegacy(fanID)] {
            do {
                let info = try smc.getKeyInfo(key: FourCharCode(fromString: key))
                if info.dataSize > 0 { return key }
            } catch {
                continue
            }
        }
        return nil
    }

    /// 内部同步实现：设置单个风扇转速（调用方需持有 lock）
    private func setFanSpeedInternal(fanID: Int, rpm: Double) -> (Bool, String) {
        do {
            try ensureOpen()

            let fanCount = Int(try smc.readUInt8(SMCKeys.fanCount))
            guard fanID >= 0 && fanID < fanCount else {
                return (false, "无效的风扇 ID: \(fanID)")
            }

            let minRPM = try smc.readFanSpeed(SMCKeys.fanMinSpeed(fanID))
            let maxRPM = try smc.readFanSpeed(SMCKeys.fanMaxSpeed(fanID))

            // 增加基本安全检查
            guard minRPM >= 0 && maxRPM >= 0 && maxRPM <= 10000 else {
                return (false, "风扇 \(fanID) 转速范围异常: \(minRPM)-\(maxRPM)")
            }
            let clampedRPM = max(minRPM, min(maxRPM, rpm))

            // 切换手动模式
            guard let modeKey = detectModeKey(fanID: fanID) else {
                return (false, "未找到风扇模式键")
            }

            // 尝试 Ftst (旧款需要，M5 Pro 无此键会跳过)
            if isFtstAvailable() {
                try? smc.writeUInt8(SMCKeys.forceMode, value: 1)
                usleep(500_000)
            }

            // 重试设置手动模式
            var manualSet = false
            for _ in 1...200 {
                do {
                    try smc.writeUInt8(modeKey, value: 1)
                    let mode = try smc.readUInt8(modeKey)
                    if mode == 1 { manualSet = true; break }
                } catch {
                    // 继续重试
                }
                usleep(50_000)
            }

            guard manualSet else {
                return (false, "无法切换到手动模式")
            }

            // 设置目标转速
            var targetSet = false
            for _ in 1...200 {
                do {
                    try smc.writeFanSpeed(SMCKeys.fanTargetSpeed(fanID), rpm: clampedRPM)
                    let readBack = try smc.readFanSpeed(SMCKeys.fanTargetSpeed(fanID))
                    if abs(readBack - clampedRPM) < 100 { targetSet = true; break }
                } catch {
                    // 继续重试
                }
                usleep(50_000)
            }

            if targetSet {
                return (true, "风扇 \(fanID) 已设置为 \(Int(clampedRPM)) RPM")
            } else {
                // 设置失败，恢复自动模式
                try? smc.writeUInt8(modeKey, value: 0)
                return (false, "无法设置目标转速")
            }
        } catch {
            return (false, "\(error)")
        }
    }

    /// 内部同步实现：恢复单个风扇自动控制（调用方需持有 lock）
    private func resetFanInternal(fanID: Int) -> (Bool, String) {
        do {
            try ensureOpen()

            let fanCount = Int(try smc.readUInt8(SMCKeys.fanCount))
            guard fanID >= 0 && fanID < fanCount else {
                return (false, "无效的风扇 ID: \(fanID)")
            }

            // 清除 Ftst 强制模式（旧款 Mac 需要，M5 Pro 无此键会跳过）
            if isFtstAvailable() {
                try? smc.writeUInt8(SMCKeys.forceMode, value: 0)
            }

            guard let modeKey = detectModeKey(fanID: fanID) else {
                return (false, "未找到风扇模式键")
            }

            try smc.writeUInt8(modeKey, value: 0)
            return (true, "风扇 \(fanID) 已恢复自动控制")
        } catch {
            return (false, "\(error)")
        }
    }

    func setFanSpeed(fanID: Int, rpm: Double, withReply reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        let result = setFanSpeedInternal(fanID: fanID, rpm: rpm)
        lock.unlock()
        reply(result.0, result.1)
    }

    func resetFan(fanID: Int, withReply reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        let result = resetFanInternal(fanID: fanID)
        lock.unlock()
        reply(result.0, result.1)
    }

    func setAllFansMax(withReply reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try ensureOpen()
            let fanCount = Int(try smc.readUInt8(SMCKeys.fanCount))

            var errors: [String] = []
            for i in 0..<fanCount {
                let maxRPM = try smc.readFanSpeed(SMCKeys.fanMaxSpeed(i))
                let result = setFanSpeedInternal(fanID: i, rpm: maxRPM)
                if !result.0 {
                    errors.append("风扇 \(i): \(result.1)")
                }
            }

            if errors.isEmpty {
                reply(true, "所有风扇已设为最大转速")
            } else {
                reply(false, errors.joined(separator: "; "))
            }
        } catch {
            reply(false, "\(error)")
        }
    }

    func resetAllFans(withReply reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try ensureOpen()
            let fanCount = Int(try smc.readUInt8(SMCKeys.fanCount))

            // 关闭 Ftst（M5 Pro 无此键会跳过）
            if isFtstAvailable() {
                try? smc.writeUInt8(SMCKeys.forceMode, value: 0)
            }

            // 恢复每个风扇自动模式
            for i in 0..<fanCount {
                if let modeKey = detectModeKey(fanID: i) {
                    try? smc.writeUInt8(modeKey, value: 0)
                }
            }

            reply(true, "已恢复自动控制")
        } catch {
            reply(false, "\(error)")
        }
    }

    func ping(withReply reply: @escaping (Bool) -> Void) {
        reply(true)
    }
}
