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

    /// 上次配置评估应用的转速百分比（防重复操作）
    private var lastAppliedPercent: Double?

    /// 直接 SMC 写入是否可用（避免反复尝试失败）
    private var directWriteAvailable: Bool?

    public init(interval: TimeInterval = 2.0) {
        self.interval = interval
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
        xpcConnection?.invalidate()
        xpcConnection = nil
        smc.close()
        isConnected = false
    }

    // MARK: - 风扇控制 (通过 XPC 连接到 root daemon)

    @Published public var controlMessage: String?
    @Published public var controlError: String?

    private var xpcConnection: NSXPCConnection?

    /// 获取 XPC 代理
    private func getHelper() -> HelperProtocol? {
        if xpcConnection == nil {
            let conn = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            conn.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.xpcConnection = nil }
            }
            conn.resume()
            xpcConnection = conn
        }
        return xpcConnection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.controlError = "XPC: \(error.localizedDescription)"
            }
        } as? HelperProtocol
    }

    /// 检测可用的模式键
    private func detectModeKey(fanID: Int) -> String? {
        for key in [SMCKeys.fanMode(fanID), SMCKeys.fanModeLegacy(fanID)] {
            do {
                let info = try smc.getKeyInfo(key: FourCharCode(fromString: key))
                if info.dataSize > 0 { return key }
            } catch { continue }
        }
        return nil
    }

    /// 设置单个风扇转速
    public func setFanSpeed(fanID: Int, rpm: Double) {
        controlMessage = nil
        controlError = nil

        guard let helper = getHelper() else {
            controlError = "Helper 未安装，请先点击 Install Helper"
            return
        }
        helper.setFanSpeed(fanID: fanID, rpm: rpm) { [weak self] success, msg in
            Task { @MainActor in
                if success {
                    self?.controlMessage = msg
                } else {
                    self?.controlError = msg
                }
            }
        }
    }

    /// 清除配置评估状态
    public func clearProfileState() {
        lastAppliedPercent = nil
        profileManager?.resetEvaluationState()
    }

    /// 所有风扇全速
    public func setAllFansMax() {
        controlMessage = nil
        controlError = nil

        guard let helper = getHelper() else {
            controlError = "Helper 未安装"
            return
        }
        helper.setAllFansMax { [weak self] success, msg in
            Task { @MainActor in
                if success {
                    self?.controlMessage = msg
                } else {
                    self?.controlError = msg
                }
            }
        }
    }

    /// 恢复自动控制
    public func resetAllFans() {
        controlMessage = nil
        controlError = nil
        fanResetCounter += 1

        guard let helper = getHelper() else {
            controlError = "Helper 未安装"
            return
        }
        helper.resetAllFans { [weak self] success, msg in
            Task { @MainActor in
                if success {
                    self?.controlMessage = msg
                } else {
                    self?.controlError = msg
                }
            }
        }
    }

    /// 恢复单个风扇自动控制
    public func resetFan(fanID: Int) {
        controlMessage = nil
        controlError = nil

        guard let helper = getHelper() else {
            controlError = "Helper 未安装"
            return
        }
        helper.resetFan(fanID: fanID) { [weak self] success, msg in
            Task { @MainActor in
                if success {
                    self?.controlMessage = msg
                } else {
                    self?.controlError = msg
                }
            }
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

    /// 评估激活的配置并通过 XPC 应用风扇转速
    private func evaluateProfile() {
        guard let pm = profileManager else { return }
        guard let targetPercent = pm.evaluateActiveProfile(maxTemp: maxTemp, battery: battery) else {
            // 无匹配规则 → 恢复自动（仅在之前是配置控制时）
            if lastAppliedPercent != nil {
                lastAppliedPercent = nil
                resetAllFans()
            }
            return
        }

        // 避免重复写入相同的转速
        if let last = lastAppliedPercent, abs(last - targetPercent) < 1 {
            return
        }

        lastAppliedPercent = targetPercent

        // 通过 XPC 设置风扇
        if targetPercent >= 100 {
            setAllFansMax()
        } else {
            for fan in fans {
                let rpm = fan.minRPM + (fan.maxRPM - fan.minRPM) * targetPercent / 100.0
                setFanSpeed(fanID: fan.id, rpm: rpm)
            }
        }
    }
}
