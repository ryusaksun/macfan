import Foundation

// MARK: - 配置方案模型

/// 风扇控制配置方案
public struct FanProfile: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var rules: [FanRule]
    public var condition: ProfileCondition

    public init(
        id: UUID = UUID(),
        name: String = "New Profile",
        isEnabled: Bool = true,
        rules: [FanRule] = [],
        condition: ProfileCondition = .always
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.rules = rules
        self.condition = condition
    }

    /// 预设：全速模式
    public static var maxSpeed: FanProfile {
        FanProfile(
            name: "Full Speed",
            rules: [FanRule(tempThreshold: 0, fanSpeedPercent: 100)],
            condition: .always
        )
    }

    /// 预设：安静模式
    public static var quiet: FanProfile {
        FanProfile(
            name: "Quiet",
            rules: [
                FanRule(tempThreshold: 80, fanSpeedPercent: 100),
                FanRule(tempThreshold: 70, fanSpeedPercent: 60),
                FanRule(tempThreshold: 60, fanSpeedPercent: 30),
            ],
            condition: .always
        )
    }

    /// 预设：性能模式
    public static var performance: FanProfile {
        FanProfile(
            name: "Performance",
            rules: [
                FanRule(tempThreshold: 70, fanSpeedPercent: 100),
                FanRule(tempThreshold: 50, fanSpeedPercent: 70),
                FanRule(tempThreshold: 40, fanSpeedPercent: 50),
            ],
            condition: .always
        )
    }
}

/// 温度 → 转速映射规则
public struct FanRule: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var tempThreshold: Double   // 温度阈值 °C
    public var fanSpeedPercent: Double  // 风扇转速百分比 0-100

    public init(
        id: UUID = UUID(),
        tempThreshold: Double = 60,
        fanSpeedPercent: Double = 50
    ) {
        self.id = id
        self.tempThreshold = tempThreshold
        self.fanSpeedPercent = fanSpeedPercent
    }
}

/// 配置方案触发条件
public enum ProfileCondition: Codable, Sendable {
    case always               // 始终生效
    case charging             // 仅充电时
    case onBattery            // 仅电池供电时
    case batteryBelow(Int)    // 电池低于 X%
}

extension ProfileCondition: Equatable {}
