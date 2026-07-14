import Foundation
import Combine

// MARK: - 数据模型

public struct FanInfo: Identifiable, Sendable {
    public let id: Int
    public var actualRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var targetRPM: Double

    public var percent: Double {
        guard maxRPM > minRPM, actualRPM > 0 else { return 0 }
        return max(0, min(100, (actualRPM - minRPM) / (maxRPM - minRPM) * 100))
    }

    public var isStopped: Bool { actualRPM <= 0 }
}

public struct TempInfo: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let name: String
    public var value: Double

    public var category: TempCategory {
        if name.contains("CPU") || name.contains("Core") || name.contains("E-Core") || name.contains("P-Core") {
            return .cpu
        } else if name.contains("GPU") {
            return .gpu
        } else if name.contains("Memory") {
            return .memory
        } else if name.contains("SSD") || name.contains("NVMe") {
            return .storage
        } else if name.contains("Battery") {
            return .battery
        } else {
            return .other
        }
    }

    public enum TempCategory: String, CaseIterable, Sendable {
        case cpu = "CPU"
        case gpu = "GPU"
        case memory = "Memory"
        case storage = "Storage"
        case battery = "Battery"
        case other = "Other"
    }
}

// MARK: - FanMonitor

@MainActor
public final class FanMonitor: ObservableObject {
    @Published public var fans: [FanInfo] = []
    @Published public var temperatures: [TempInfo] = []
    @Published public var maxTemp: Double = 0
    @Published public var battery: BatteryInfo = BatteryInfo()
    @Published public var isConnected = false
    @Published public var lastError: String?
    @Published public var fanResetCounter: Int = 0

    private let smc = SMCKit()
    private let batteryService = BatteryService()
    private var timer: Timer?
    private var interval: TimeInterval

    /// 已发现的有效温度键（首次扫描后缓存）
    private var discoveredTempKeys: [(key: String, name: String)] = []

    /// 配置管理器引用（用于自动评估配置）
    public var profileManager: ProfileManager?

    /// 上次由配置成功应用的转速百分比。
    private var lastAppliedPercent: Double?
    private var pendingProfilePercent: Double?
    /// 配置请求可能已把硬件置于手动模式；只有确认恢复成功后才能清除。
    private var manualControlMayBeActive = false
    private var profileRequestGeneration = 0

    private let fanControlClient: any FanControlClient

    public init(
        interval: TimeInterval = 2.0,
        fanControlClient: (any FanControlClient)? = nil
    ) {
        self.interval = interval
        self.fanControlClient = fanControlClient ?? XPCFanControlClient()
    }

    public func start() {
        if isConnected {
            if timer == nil {
                scheduleTimer()
            }
            refresh()
            return
        }

        do {
            try smc.open()
            isConnected = true
            lastError = nil

            // 首次扫描发现可用传感器
            discoverSensors()
            refresh()

            scheduleTimer()
        } catch {
            isConnected = false
            lastError = "\(error)"
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        fanControlClient.invalidate()
        smc.close()
        isConnected = false
    }

    // MARK: - 风扇控制 (通过 XPC 连接到 root daemon)

    @Published public var controlMessage: String?
    @Published public var controlError: String?

    /// 设置单个风扇转速。
    public func setFanSpeed(
        fanID: Int,
        rpm: Double,
        completion: FanControlCompletion? = nil
    ) {
        invalidateProfileRequest(clearApplied: true)
        beginControlOperation()
        fanControlClient.setFanSpeed(fanID: fanID, rpm: rpm) { [weak self] result in
            self?.finishControlOperation(result)
            if result.success {
                self?.manualControlMayBeActive = true
            }
            completion?(result)
        }
    }

    /// 按每个风扇自己的转速范围设置统一百分比。
    public func setAllFans(
        percent: Double,
        completion: FanControlCompletion? = nil
    ) {
        invalidateProfileRequest(clearApplied: true)
        beginControlOperation()
        fanControlClient.setAllFans(percent: percent) { [weak self] result in
            self?.finishControlOperation(result)
            if result.success {
                self?.manualControlMayBeActive = true
            }
            completion?(result)
        }
    }

    /// 清除配置评估状态并使尚未完成的配置请求失效。
    public func clearProfileState() {
        invalidateProfileRequest(clearApplied: true)
        profileManager?.resetEvaluationState()
    }

    /// 切换配置时保留“可能处于手动模式”的事实，使无匹配规则的新配置能先恢复自动。
    public func profileDidChange() {
        invalidateProfileRequest(clearApplied: true)
        profileManager?.resetEvaluationState()
        evaluateProfile()
    }

    /// 所有风扇全速。
    public func setAllFansMax(completion: FanControlCompletion? = nil) {
        invalidateProfileRequest(clearApplied: true)
        beginControlOperation()
        fanControlClient.setAllFansMax { [weak self] result in
            self?.finishControlOperation(result)
            if result.success {
                self?.manualControlMayBeActive = true
            }
            completion?(result)
        }
    }

    /// 恢复自动控制。只有 Helper 明确成功后才更新 UI 的恢复计数。
    public func resetAllFans(
        invalidateProfile: Bool = true,
        completion: FanControlCompletion? = nil
    ) {
        if invalidateProfile {
            invalidateProfileRequest(clearApplied: true)
        }
        beginControlOperation()
        fanControlClient.resetAllFans { [weak self] result in
            guard let self else {
                completion?(result)
                return
            }
            finishControlOperation(result)
            if result.success {
                manualControlMayBeActive = false
                lastAppliedPercent = nil
                fanResetCounter += 1
            }
            completion?(result)
        }
    }

    /// 恢复单个风扇自动控制。
    public func resetFan(
        fanID: Int,
        completion: FanControlCompletion? = nil
    ) {
        invalidateProfileRequest(clearApplied: true)
        beginControlOperation()
        fanControlClient.resetFan(fanID: fanID) { [weak self] result in
            self?.finishControlOperation(result)
            completion?(result)
        }
    }

    private func beginControlOperation() {
        controlMessage = nil
        controlError = nil
    }

    private func finishControlOperation(_ result: FanControlResult) {
        if result.success {
            controlMessage = result.message
            controlError = nil
        } else {
            controlMessage = nil
            controlError = result.message
        }
    }

    private func invalidateProfileRequest(clearApplied: Bool) {
        profileRequestGeneration &+= 1
        pendingProfilePercent = nil
        if clearApplied {
            lastAppliedPercent = nil
        }
    }

    // MARK: - 内部

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    public func updateInterval(_ newInterval: TimeInterval) {
        let clampedInterval = max(1.0, newInterval)
        guard abs(interval - clampedInterval) >= 0.01 else { return }

        interval = clampedInterval
        if isConnected {
            scheduleTimer()
        }
    }

    private func discoverSensors() {
        discoveredTempKeys = []

        for (key, name) in SMCKeys.temperatureKeys {
            do {
                let temp = try smc.readTemperature(key)
                if temp > 0 && temp < 130 {
                    discoveredTempKeys.append((key, name))
                }
            } catch {
                continue
            }
        }
    }

    private func refresh() {
        // 读取风扇
        do {
            let count = Int(try smc.readUInt8(SMCKeys.fanCount))
            var newFans: [FanInfo] = []

            for i in 0..<count {
                let actual = (try? smc.readFanSpeed(SMCKeys.fanActualSpeed(i))) ?? 0
                let min = (try? smc.readFanSpeed(SMCKeys.fanMinSpeed(i))) ?? 0
                let max = (try? smc.readFanSpeed(SMCKeys.fanMaxSpeed(i))) ?? 0
                let target = (try? smc.readFanSpeed(SMCKeys.fanTargetSpeed(i))) ?? 0

                newFans.append(FanInfo(
                    id: i,
                    actualRPM: actual,
                    minRPM: min,
                    maxRPM: max,
                    targetRPM: target
                ))
            }

            fans = newFans
        } catch {
            // 保持上次数据
        }

        // 读取温度
        var newTemps: [TempInfo] = []
        var maxT: Double = 0

        for (key, name) in discoveredTempKeys {
            do {
                let temp = try smc.readTemperature(key)
                if temp >= 0 && temp < 130 {
                    newTemps.append(TempInfo(key: key, name: name, value: temp))
                    maxT = max(maxT, temp)
                }
            } catch {
                continue
            }
        }

        temperatures = newTemps
        maxTemp = maxT

        // 读取电池
        battery = batteryService.getBatteryInfo()

        // 评估激活的配置方案
        evaluateProfile()
    }

    /// 评估激活的配置并通过单次 XPC 请求应用所有风扇。
    func evaluateProfile() {
        guard let pm = profileManager else { return }
        guard let targetPercent = pm.evaluateActiveProfile(maxTemp: maxTemp, battery: battery) else {
            guard manualControlMayBeActive, pendingProfilePercent == nil else { return }
            beginProfileReset()
            return
        }

        guard targetPercent.isFinite, (0...100).contains(targetPercent) else {
            controlError = "配置返回了无效的风扇转速百分比: \(targetPercent)"
            return
        }
        if let lastAppliedPercent, abs(lastAppliedPercent - targetPercent) < 1 {
            return
        }
        if let pendingProfilePercent, abs(pendingProfilePercent - targetPercent) < 1 {
            return
        }

        beginProfileApply(percent: targetPercent)
    }

    private func beginProfileApply(percent: Double) {
        profileRequestGeneration &+= 1
        let generation = profileRequestGeneration
        pendingProfilePercent = percent
        manualControlMayBeActive = true
        beginControlOperation()

        fanControlClient.setAllFans(percent: percent) { [weak self] result in
            guard let self, generation == profileRequestGeneration else { return }
            pendingProfilePercent = nil
            finishControlOperation(result)
            if result.success {
                lastAppliedPercent = percent
            }
        }
    }

    private func beginProfileReset() {
        profileRequestGeneration &+= 1
        let generation = profileRequestGeneration
        pendingProfilePercent = -1
        beginControlOperation()

        fanControlClient.resetAllFans { [weak self] result in
            guard let self, generation == profileRequestGeneration else { return }
            pendingProfilePercent = nil
            finishControlOperation(result)
            if result.success {
                lastAppliedPercent = nil
                manualControlMayBeActive = false
                fanResetCounter += 1
            }
        }
    }
}
