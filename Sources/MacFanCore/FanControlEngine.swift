import Foundation

/// 风扇控制所需的最小 SMC 接口，便于在不访问真实硬件的情况下测试控制流程。
public protocol SMCBackend: AnyObject {
    func open() throws
    func close()
    func getKeyInfo(key: FourCharCode) throws -> SMCKeyDataKeyInfo
    func readUInt8(_ key: String) throws -> UInt8
    func writeUInt8(_ key: String, value: UInt8) throws
    func readFanSpeed(_ key: String) throws -> Double
    func writeFanSpeed(_ key: String, rpm: Double) throws
}

extension SMCKit: SMCBackend {}

public struct FanControlResult: Sendable, Equatable {
    public let success: Bool
    public let message: String

    public init(success: Bool, message: String) {
        self.success = success
        self.message = message
    }
}

/// 统一的风扇写入流程。调用均为同步操作，并由内部锁串行化。
public final class FanControlEngine: @unchecked Sendable {
    private let smc: any SMCBackend
    private let retryCount: Int
    private let retryDelayMicroseconds: UInt32
    private let forceModeDelayMicroseconds: UInt32
    private let lock = NSLock()
    private var ftstAvailable: Bool?

    public init(
        smc: any SMCBackend,
        retryCount: Int = 200,
        retryDelayMicroseconds: UInt32 = 50_000,
        forceModeDelayMicroseconds: UInt32 = 500_000
    ) {
        self.smc = smc
        self.retryCount = max(1, retryCount)
        self.retryDelayMicroseconds = retryDelayMicroseconds
        self.forceModeDelayMicroseconds = forceModeDelayMicroseconds
    }

    public func setFanSpeed(fanID: Int, rpm: Double) -> FanControlResult {
        withLock {
            do {
                try smc.open()
                return setFanSpeedInternal(fanID: fanID, rpm: rpm)
            } catch {
                return failure(error)
            }
        }
    }

    public func setAllFans(percent: Double) -> FanControlResult {
        withLock {
            do {
                try smc.open()
                guard percent.isFinite, (0...100).contains(percent) else {
                    return FanControlResult(success: false, message: "无效的风扇转速百分比: \(percent)")
                }

                let fanCount = try readFanCount()
                var errors: [String] = []

                for fanID in 0..<fanCount {
                    do {
                        let range = try readValidatedRange(fanID: fanID)
                        let rpm = range.min + (range.max - range.min) * percent / 100.0
                        let result = setFanSpeedInternal(fanID: fanID, rpm: rpm)
                        if !result.success {
                            errors.append("风扇 \(fanID): \(result.message)")
                            break
                        }
                    } catch {
                        errors.append("风扇 \(fanID): \(describe(error))")
                        break
                    }
                }

                guard errors.isEmpty else {
                    let rollback = resetAllFansInternal(fanCount: fanCount)
                    let suffix = rollback.success ? "；已恢复全部风扇为自动控制" : "；自动恢复失败: \(rollback.message)"
                    return FanControlResult(success: false, message: errors.joined(separator: "; ") + suffix)
                }

                return FanControlResult(success: true, message: "所有风扇已设置为 \(Int(percent.rounded()))%")
            } catch {
                return failure(error)
            }
        }
    }

    public func setAllFansMax() -> FanControlResult {
        setAllFans(percent: 100)
    }

    public func resetFan(fanID: Int) -> FanControlResult {
        withLock {
            do {
                try smc.open()
                let fanCount = try readFanCount()
                guard fanID >= 0, fanID < fanCount else {
                    return FanControlResult(success: false, message: "无效的风扇 ID: \(fanID)")
                }
                return resetFanInternal(fanID: fanID, clearForceMode: true)
            } catch {
                return failure(error)
            }
        }
    }

    public func resetAllFans() -> FanControlResult {
        withLock {
            do {
                try smc.open()
                let fanCount = Int(try smc.readUInt8(SMCKeys.fanCount))
                return resetAllFansInternal(fanCount: fanCount)
            } catch {
                return failure(error)
            }
        }
    }

    private func setFanSpeedInternal(fanID: Int, rpm: Double) -> FanControlResult {
        do {
            let fanCount = try readFanCount()
            guard fanID >= 0, fanID < fanCount else {
                return FanControlResult(success: false, message: "无效的风扇 ID: \(fanID)")
            }
            guard rpm.isFinite else {
                return FanControlResult(success: false, message: "无效的目标转速: \(rpm)")
            }

            let range = try readValidatedRange(fanID: fanID)
            let targetRPM = max(range.min, min(range.max, rpm))
            guard let modeKey = detectModeKey(fanID: fanID) else {
                return FanControlResult(success: false, message: "未找到风扇模式键")
            }

            var forceModeEnabled = false
            if isFtstAvailable() {
                do {
                    try smc.writeUInt8(SMCKeys.forceMode, value: 1)
                    forceModeEnabled = true
                    sleepMicroseconds(forceModeDelayMicroseconds)
                } catch {
                    return FanControlResult(success: false, message: "无法启用 Force 模式: \(describe(error))")
                }
            }

            guard retryUInt8Write(key: modeKey, value: 1) else {
                let rollback = rollbackManualMode(modeKey: modeKey, clearForceMode: forceModeEnabled)
                return FanControlResult(
                    success: false,
                    message: appendRollback("无法切换到手动模式", rollback: rollback)
                )
            }

            guard retryFanSpeedWrite(key: SMCKeys.fanTargetSpeed(fanID), rpm: targetRPM) else {
                let rollback = rollbackManualMode(modeKey: modeKey, clearForceMode: forceModeEnabled)
                return FanControlResult(
                    success: false,
                    message: appendRollback("无法设置目标转速", rollback: rollback)
                )
            }

            return FanControlResult(success: true, message: "风扇 \(fanID) 已设置为 \(Int(targetRPM)) RPM")
        } catch {
            return failure(error)
        }
    }

    private func resetFanInternal(fanID: Int, clearForceMode: Bool) -> FanControlResult {
        guard let modeKey = detectModeKey(fanID: fanID) else {
            return FanControlResult(success: false, message: "未找到风扇 \(fanID) 的模式键")
        }

        var errors: [String] = []
        if clearForceMode, isFtstAvailable(), !retryUInt8Write(key: SMCKeys.forceMode, value: 0) {
            errors.append("无法关闭 Force 模式")
        }
        if !retryUInt8Write(key: modeKey, value: 0) {
            errors.append("无法将 \(modeKey) 恢复为自动模式")
        }

        if errors.isEmpty {
            return FanControlResult(success: true, message: "风扇 \(fanID) 已恢复自动控制")
        }
        return FanControlResult(success: false, message: errors.joined(separator: "; "))
    }

    private func resetAllFansInternal(fanCount: Int) -> FanControlResult {
        var errors: [String] = []
        if isFtstAvailable(), !retryUInt8Write(key: SMCKeys.forceMode, value: 0) {
            errors.append("无法关闭 Force 模式")
        }

        for fanID in 0..<fanCount {
            let result = resetFanInternal(fanID: fanID, clearForceMode: false)
            if !result.success {
                errors.append("风扇 \(fanID): \(result.message)")
            }
        }

        if errors.isEmpty {
            let message = fanCount > 0 ? "已恢复自动控制" : "未检测到风扇；Force 模式已关闭或不存在"
            return FanControlResult(success: true, message: message)
        }
        return FanControlResult(success: false, message: errors.joined(separator: "; "))
    }

    private func rollbackManualMode(modeKey: String, clearForceMode: Bool) -> FanControlResult {
        var errors: [String] = []
        if !retryUInt8Write(key: modeKey, value: 0) {
            errors.append("无法恢复 \(modeKey)=0")
        }
        if clearForceMode, !retryUInt8Write(key: SMCKeys.forceMode, value: 0) {
            errors.append("无法恢复 Ftst=0")
        }
        if errors.isEmpty {
            return FanControlResult(success: true, message: "已恢复自动控制")
        }
        return FanControlResult(success: false, message: errors.joined(separator: "; "))
    }

    private func retryUInt8Write(key: String, value: UInt8) -> Bool {
        for attempt in 0..<retryCount {
            do {
                try smc.writeUInt8(key, value: value)
                if try smc.readUInt8(key) == value {
                    return true
                }
            } catch {
                // 下一次重试会重新执行完整的写入和读回。
            }
            if attempt + 1 < retryCount {
                sleepMicroseconds(retryDelayMicroseconds)
            }
        }
        return false
    }

    private func retryFanSpeedWrite(key: String, rpm: Double) -> Bool {
        for attempt in 0..<retryCount {
            do {
                try smc.writeFanSpeed(key, rpm: rpm)
                if abs(try smc.readFanSpeed(key) - rpm) < 100 {
                    return true
                }
            } catch {
                // 下一次重试会重新执行完整的写入和读回。
            }
            if attempt + 1 < retryCount {
                sleepMicroseconds(retryDelayMicroseconds)
            }
        }
        return false
    }

    private func readFanCount() throws -> Int {
        let count = Int(try smc.readUInt8(SMCKeys.fanCount))
        guard count > 0 else {
            throw FanControlEngineError.noFans
        }
        return count
    }

    private func readValidatedRange(fanID: Int) throws -> (min: Double, max: Double) {
        let minRPM = try smc.readFanSpeed(SMCKeys.fanMinSpeed(fanID))
        let maxRPM = try smc.readFanSpeed(SMCKeys.fanMaxSpeed(fanID))
        guard minRPM.isFinite, maxRPM.isFinite,
              minRPM >= 0, maxRPM >= minRPM else {
            throw FanControlEngineError.invalidRange(fanID: fanID, min: minRPM, max: maxRPM)
        }
        return (minRPM, maxRPM)
    }

    private func detectModeKey(fanID: Int) -> String? {
        for key in [SMCKeys.fanMode(fanID), SMCKeys.fanModeLegacy(fanID)] {
            if let info = try? smc.getKeyInfo(key: FourCharCode(fromString: key)), info.dataSize > 0 {
                return key
            }
        }
        return nil
    }

    private func isFtstAvailable() -> Bool {
        if let ftstAvailable {
            return ftstAvailable
        }
        let available = ((try? smc.getKeyInfo(key: FourCharCode(fromString: SMCKeys.forceMode)))?.dataSize ?? 0) > 0
        ftstAvailable = available
        return available
    }

    private func appendRollback(_ message: String, rollback: FanControlResult) -> String {
        rollback.success ? "\(message)；已恢复自动控制" : "\(message)；回滚失败: \(rollback.message)"
    }

    private func failure(_ error: Error) -> FanControlResult {
        FanControlResult(success: false, message: describe(error))
    }

    private func describe(_ error: Error) -> String {
        String(describing: error)
    }

    private func sleepMicroseconds(_ duration: UInt32) {
        guard duration > 0 else { return }
        usleep(duration)
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private enum FanControlEngineError: Error, CustomStringConvertible {
    case noFans
    case invalidRange(fanID: Int, min: Double, max: Double)

    var description: String {
        switch self {
        case .noFans:
            return "未检测到风扇"
        case .invalidRange(let fanID, let min, let max):
            return "风扇 \(fanID) 转速范围异常: \(min)-\(max)"
        }
    }
}
