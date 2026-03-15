import Foundation
import IOKit.ps

// MARK: - 电池信息模型

public struct BatteryInfo: Sendable {
    public var isPresent: Bool = false
    public var isCharging: Bool = false
    public var isPluggedIn: Bool = false
    public var currentCapacity: Int = 0
    public var maxCapacity: Int = 0
    public var percentage: Int = 0
    public var timeToEmpty: Int = 0     // 分钟, -1 = 计算中
    public var timeToFull: Int = 0      // 分钟, -1 = 计算中
    public var cycleCount: Int = 0
    public var temperature: Double = 0  // °C
    public var health: Int = 100        // 电池健康度 %
}

// MARK: - 电池监控服务

public final class BatteryService: @unchecked Sendable {

    public init() {}

    /// 读取当前电池状态
    public func getBatteryInfo() -> BatteryInfo {
        var info = BatteryInfo()

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        else {
            return info
        }

        info.isPresent = true

        // isPluggedIn: 电源状态为 AC 即表示插电
        if let state = desc[kIOPSPowerSourceStateKey] as? String {
            info.isPluggedIn = (state == kIOPSACPowerValue)
        }

        // isCharging: 优先使用 kIOPSIsChargingKey（更准确，区分插电但未充电的情况）
        if let isCharging = desc[kIOPSIsChargingKey] as? Bool {
            info.isCharging = isCharging
        } else {
            info.isCharging = info.isPluggedIn
        }

        if let current = desc[kIOPSCurrentCapacityKey] as? Int {
            info.currentCapacity = current
            info.percentage = current
        }

        if let maxCap = desc[kIOPSMaxCapacityKey] as? Int {
            info.maxCapacity = maxCap
            // 如果 currentCapacity 是绝对值而非百分比，重新计算百分比
            if maxCap > 0 && maxCap != 100 {
                info.percentage = info.currentCapacity * 100 / maxCap
            }
        }

        if let timeToEmpty = desc[kIOPSTimeToEmptyKey] as? Int {
            info.timeToEmpty = timeToEmpty
        }

        if let timeToFull = desc[kIOPSTimeToFullChargeKey] as? Int {
            info.timeToFull = timeToFull
        }

        return info
    }
}
