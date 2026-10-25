import Foundation
import Combine

// MARK: - 数据模型

public struct FanInfo: Identifiable, Sendable, Equatable {
    public let id: Int
    public var actualRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var targetRPM: Double
    /// SMC 风扇模式：0 = 自动，1 = 手动；nil = 无法读取
    public var mode: UInt8?

    public init(
        id: Int,
        actualRPM: Double,
        minRPM: Double,
        maxRPM: Double,
        targetRPM: Double,
        mode: UInt8? = nil
    ) {
        self.id = id
        self.actualRPM = actualRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
        self.mode = mode
    }

    public var percent: Double {
        guard actualRPM > 0 else { return 0 }
        return Self.percent(of: actualRPM, min: minRPM, max: maxRPM)
    }

    public var targetPercent: Double {
        Self.percent(of: targetRPM, min: minRPM, max: maxRPM)
    }

    public var isStopped: Bool { actualRPM <= 0 }
    public var isManual: Bool { mode == 1 }

    private static func percent(of rpm: Double, min minRPM: Double, max maxRPM: Double) -> Double {
        guard maxRPM > minRPM else { return 0 }
        return Swift.max(0, Swift.min(100, (rpm - minRPM) / (maxRPM - minRPM) * 100))
    }
}

public struct TempInfo: Identifiable, Sendable, Equatable {
    public var id: String { key }
    public let key: String
    public let name: String
    public var value: Double

    public init(key: String, name: String, value: Double) {
        self.key = key
        self.name = name
        self.value = value
    }

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

/// 最近一段时间的采样，用于绘制趋势图
public struct MonitorHistory: Equatable, Sendable {
    public static let capacity = 60

    public private(set) var fanRPM: [Double] = []
    public private(set) var maxTemp: [Double] = []
    public private(set) var temperatures: [TempInfo.TempCategory: [Double]] = [:]

    public init() {}

    mutating func record(fans: [FanInfo], temperatures temps: [TempInfo], maxTemp: Double) {
        if !fans.isEmpty {
            Self.append(fans.map(\.actualRPM).reduce(0, +) / Double(fans.count), to: &fanRPM)
        }
        if maxTemp > 0 {
            Self.append(maxTemp, to: &self.maxTemp)
        }
        for (category, values) in Dictionary(grouping: temps, by: \.category) {
            Self.append(values.map(\.value).max() ?? 0, to: &temperatures[category, default: []])
        }
    }

    private static func append(_ value: Double, to buffer: inout [Double]) {
        buffer.append(value)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }
}

/// 当前由谁控制风扇
public enum FanControlMode: Equatable, Sendable {
    /// 系统自动控制
    case system
    /// 用户手动设置的统一百分比
    case manual(percent: Double)
    /// 配置方案控制；percent 为 nil 表示当前没有匹配的规则，交由系统控制
    case profile(percent: Double?)
}

// MARK: - FanMonitor

@MainActor
public final class FanMonitor: ObservableObject {
    @Published public internal(set) var fans: [FanInfo] = []
    @Published public internal(set) var temperatures: [TempInfo] = []
    @Published public internal(set) var maxTemp: Double = 0
    @Published public internal(set) var battery: BatteryInfo = BatteryInfo()
    @Published public internal(set) var history = MonitorHistory()
    @Published public private(set) var isConnected = false
    @Published public private(set) var lastError: String?
    /// 界面展示用的控制状态，由内部状态派生
    @Published public private(set) var controlMode: FanControlMode = .system
    /// 是否有用户发起的控制请求尚未返回
    @Published public private(set) var isApplying = false
    @Published public var controlMessage: String?
    @Published public var controlError: String?

    /// 配置管理器引用（用于自动评估配置）
    public var profileManager: ProfileManager?

    public var averageFanPercent: Double {
        guard !fans.isEmpty else { return 0 }
        return fans.map(\.percent).reduce(0, +) / Double(fans.count)
    }

    private let smc = SMCKit()
    private let batteryService = BatteryService()
    private let fanControlClient: any FanControlClient
    private var timer: Timer?
    private var interval: TimeInterval

    /// 已发现的有效温度键（首次扫描后缓存）
    private var discoveredTempKeys: [(key: String, name: String)] = []
    /// 每个风扇实际可用的模式键（F0md / F0Md）
    private var modeKeys: [Int: String] = [:]

    /// 硬件可能处于手动模式时，记录是谁把它切过去的。
    /// 只有配置方案设置的手动模式才会在规则不再匹配时自动恢复；用户手动设置的会一直保留。
    enum ManualOwner {
        case none
        case user
        case profile
    }
    private(set) var manualOwner: ManualOwner = .none
    private var userManualPercent: Double?
    private var profileTargetPercent: Double?

    /// 上次由配置成功应用的转速百分比。
    private var lastAppliedPercent: Double?
    /// 正在进行的配置请求；-1 表示正在恢复自动。
    private var pendingProfilePercent: Double?
    private var profileRequestGeneration = 0
    private var userRequestGeneration = 0
    private var inFlightUserRequests = 0
    private var inFlightRequests = 0
    private var resumePercentAfterWake: Double?

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

    public func updateInterval(_ newInterval: TimeInterval) {
        let clampedInterval = max(1.0, newInterval)
        guard abs(interval - clampedInterval) >= 0.01 else { return }

        interval = clampedInterval
        if isConnected {
            scheduleTimer()
        }
    }

    // MARK: - 用户操作 (通过 XPC 连接到 root daemon)

    /// 用户手动设置所有风扇的统一百分比（按各自转速范围换算）。会停用当前配置方案。
    public func setAllFans(percent: Double, completion: FanControlCompletion? = nil) {
        if profileManager?.activeProfileID != nil {
            profileManager?.setActive(nil)
        }
        startUserControl(percent: percent, announce: true, completion: completion)
    }

    /// 恢复系统自动控制，并停用当前配置方案。
    public func restoreSystemControl(completion: FanControlCompletion? = nil) {
        if profileManager?.activeProfileID != nil {
            profileManager?.setActive(nil)
        }
        resetAllFans(completion: completion)
    }

    /// 激活配置方案；传入 nil 表示停用并恢复系统控制。
    public func activateProfile(_ id: UUID?) {
        guard let id else {
            restoreSystemControl()
            return
        }
        profileManager?.setActive(id)
        profileDidChange()
    }

    /// 恢复所有风扇为自动控制，不改变配置方案的选择（例如退出时）。
    public func resetAllFans(completion: FanControlCompletion? = nil) {
        invalidateProfileRequest()
        let generation = beginUserRequest()
        fanControlClient.resetAllFans { [weak self] result in
            guard let self else {
                completion?(result)
                return
            }
            finishRequest(isUser: true)
            if generation == userRequestGeneration {
                show(result)
                if result.success {
                    manualOwner = .none
                    userManualPercent = nil
                    lastAppliedPercent = nil
                }
                updateControlMode()
            }
            completion?(result)
        }
    }

    /// 激活的配置方案或其规则发生变化后调用，立即重新评估。
    public func profileDidChange() {
        invalidateProfileRequest()
        // 让尚未返回的手动请求不再改写状态
        userRequestGeneration &+= 1
        // 配置方案接管：若新配置没有匹配的规则，会先恢复自动
        if manualOwner == .user {
            manualOwner = .profile
        }
        userManualPercent = nil
        profileManager?.resetEvaluationState()
        evaluateProfile()
    }

    /// 清除配置评估状态并使尚未完成的配置请求失效。
    public func clearProfileState() {
        invalidateProfileRequest()
        profileManager?.resetEvaluationState()
    }

    // MARK: - 睡眠 / 唤醒

    /// 系统即将睡眠：记住用户手动设置的转速，唤醒后重新应用。
    public func prepareForSleep() {
        resumePercentAfterWake = manualOwner == .user ? userManualPercent : nil
    }

    /// 系统唤醒：SMC 可能已恢复自动，重新下发当前的控制状态。
    public func resumeAfterWake() {
        defer { resumePercentAfterWake = nil }
        lastAppliedPercent = nil
        if let percent = resumePercentAfterWake, profileManager?.activeProfile == nil {
            startUserControl(percent: percent, announce: false, completion: nil)
        }
    }

    // MARK: - 请求状态

    private func startUserControl(percent: Double, announce: Bool, completion: FanControlCompletion?) {
        invalidateProfileRequest()
        // 立即接管，避免请求返回前的定时评估把风扇恢复为自动
        manualOwner = .user
        let generation = beginUserRequest()
        fanControlClient.setAllFans(percent: percent) { [weak self] result in
            guard let self else {
                completion?(result)
                return
            }
            finishRequest(isUser: true)
            if generation == userRequestGeneration {
                if announce || !result.success {
                    show(result)
                }
                if result.success {
                    userManualPercent = percent
                }
                updateControlMode()
            }
            completion?(result)
        }
    }

    private func beginUserRequest() -> Int {
        userRequestGeneration &+= 1
        inFlightUserRequests += 1
        inFlightRequests += 1
        isApplying = true
        controlMessage = nil
        controlError = nil
        return userRequestGeneration
    }

    private func finishRequest(isUser: Bool) {
        inFlightRequests = max(0, inFlightRequests - 1)
        if isUser {
            inFlightUserRequests = max(0, inFlightUserRequests - 1)
            isApplying = inFlightUserRequests > 0
        }
    }

    private func show(_ result: FanControlResult) {
        if result.success {
            controlMessage = result.message
            controlError = nil
        } else {
            controlMessage = nil
            controlError = result.message
        }
    }

    private func invalidateProfileRequest() {
        profileRequestGeneration &+= 1
        pendingProfilePercent = nil
        lastAppliedPercent = nil
    }

    private func updateControlMode() {
        let mode: FanControlMode
        if manualOwner == .user, let userManualPercent {
            mode = .manual(percent: userManualPercent)
        } else if profileManager?.activeProfile != nil {
            mode = .profile(percent: profileTargetPercent)
        } else {
            mode = .system
        }
        if mode != controlMode {
            controlMode = mode
        }
    }

    // MARK: - 内部

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer.tolerance = interval * 0.1
        // common 模式下，菜单或滑块交互期间也会继续刷新
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
        readFans()
        readTemperatures()
        history.record(fans: fans, temperatures: temperatures, maxTemp: maxTemp)

        let newBattery = batteryService.getBatteryInfo()
        if newBattery != battery {
            battery = newBattery
        }

        reconcileWithHardware()
        // 没有风扇的机型（如 MacBook Air）不需要评估配置，否则会反复请求失败
        if !fans.isEmpty {
            evaluateProfile()
        }
    }

    private func readFans() {
        guard let count = try? Int(smc.readUInt8(SMCKeys.fanCount)) else {
            return // 保持上次数据
        }

        var newFans: [FanInfo] = []
        for i in 0..<count {
            newFans.append(FanInfo(
                id: i,
                actualRPM: (try? smc.readFanSpeed(SMCKeys.fanActualSpeed(i))) ?? 0,
                minRPM: (try? smc.readFanSpeed(SMCKeys.fanMinSpeed(i))) ?? 0,
                maxRPM: (try? smc.readFanSpeed(SMCKeys.fanMaxSpeed(i))) ?? 0,
                targetRPM: (try? smc.readFanSpeed(SMCKeys.fanTargetSpeed(i))) ?? 0,
                mode: readFanMode(i)
            ))
        }
        if newFans != fans {
            fans = newFans
        }
    }

    private func readFanMode(_ fanID: Int) -> UInt8? {
        if let key = modeKeys[fanID] {
            return try? smc.readUInt8(key)
        }
        for key in [SMCKeys.fanMode(fanID), SMCKeys.fanModeLegacy(fanID)] {
            if let value = try? smc.readUInt8(key) {
                modeKeys[fanID] = key
                return value
            }
        }
        return nil
    }

    private func readTemperatures() {
        var newTemps: [TempInfo] = []
        var maxT: Double = 0

        for (key, name) in discoveredTempKeys {
            guard let temp = try? smc.readTemperature(key), temp >= 0, temp < 130 else { continue }
            newTemps.append(TempInfo(key: key, name: name, value: temp))
            maxT = max(maxT, temp)
        }

        if newTemps != temperatures {
            temperatures = newTemps
        }
        if maxT != maxTemp {
            maxTemp = maxT
        }
    }

    /// 用硬件实际的风扇模式校正内部状态。
    /// 命令行工具、睡眠唤醒或上次异常退出都可能在 App 不知情时改变风扇模式。
    func reconcileWithHardware() {
        guard inFlightRequests == 0, pendingProfilePercent == nil, !fans.isEmpty else { return }
        let modes = fans.compactMap(\.mode)
        guard modes.count == fans.count else { return }

        if modes.allSatisfy({ $0 == 0 }) {
            switch manualOwner {
            case .none:
                return
            case .user:
                userManualPercent = nil
            case .profile:
                // 配置仍激活时会在本轮评估中重新应用
                lastAppliedPercent = nil
            }
            manualOwner = .none
            updateControlMode()
        } else if manualOwner == .none, modes.contains(1) {
            if profileManager?.activeProfile != nil {
                // 交给配置方案接管：规则匹配则重新应用，否则恢复自动
                manualOwner = .profile
            } else {
                let manualFans = fans.filter(\.isManual)
                manualOwner = .user
                userManualPercent = (manualFans.map(\.targetPercent).reduce(0, +) / Double(manualFans.count)).rounded()
                updateControlMode()
            }
        }
    }

    /// 评估激活的配置并通过单次 XPC 请求应用所有风扇。
    func evaluateProfile() {
        guard let pm = profileManager else { return }
        let targetPercent = pm.evaluateActiveProfile(maxTemp: maxTemp, battery: battery)
        if profileTargetPercent != targetPercent {
            profileTargetPercent = targetPercent
        }
        updateControlMode()

        // 用户请求进行中时不发起配置请求，避免两者在 Helper 中交错执行
        guard inFlightUserRequests == 0 else { return }

        guard let targetPercent else {
            guard manualOwner == .profile, pendingProfilePercent == nil else { return }
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
        manualOwner = .profile
        userManualPercent = nil
        inFlightRequests += 1

        fanControlClient.setAllFans(percent: percent) { [weak self] result in
            guard let self else { return }
            finishRequest(isUser: false)
            guard generation == profileRequestGeneration else { return }
            pendingProfilePercent = nil
            if result.success {
                lastAppliedPercent = percent
                controlError = nil
            } else {
                controlError = result.message
            }
        }
    }

    private func beginProfileReset() {
        profileRequestGeneration &+= 1
        let generation = profileRequestGeneration
        pendingProfilePercent = -1
        inFlightRequests += 1

        fanControlClient.resetAllFans { [weak self] result in
            guard let self else { return }
            finishRequest(isUser: false)
            guard generation == profileRequestGeneration else { return }
            pendingProfilePercent = nil
            if result.success {
                lastAppliedPercent = nil
                manualOwner = .none
                controlError = nil
            } else {
                controlError = result.message
            }
            updateControlMode()
        }
    }
}
