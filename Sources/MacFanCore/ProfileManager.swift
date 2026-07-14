import Foundation

/// 配置方案持久化管理
@MainActor
public final class ProfileManager: ObservableObject {
    @Published public var profiles: [FanProfile] = []
    @Published public var activeProfileID: UUID?

    /// 当前激活的配置
    public var activeProfile: FanProfile? {
        guard let id = activeProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    private let fileURL: URL

    @Published public var saveError: String?
    @Published public var loadError: String?

    public convenience init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            self.init(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macfan_profiles.json"))
            return
        }
        self.init(fileURL: appSupport.appendingPathComponent("MacFan/profiles.json"))
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            loadError = "无法创建配置目录: \(error.localizedDescription)"
            NSLog("MacFan: 无法创建配置目录: \(error)")
        }
        load()
    }

    // MARK: - CRUD

    public func addProfile(_ profile: FanProfile) {
        profiles.append(profile)
        save()
    }

    public func updateProfile(_ profile: FanProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            if activeProfileID == profile.id {
                resetEvaluationState()
            }
            save()
        }
    }

    public func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = nil
            resetEvaluationState()
        }
        save()
    }

    public func setActive(_ id: UUID?) {
        activeProfileID = id
        resetEvaluationState()
        save()
    }

    public func resetEvaluationState() {
        lastMatchedRuleIndex = nil
    }

    // MARK: - 持久化

    private func save() {
        let data = SaveData(profiles: profiles, activeProfileID: activeProfileID)
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "保存配置失败: \(error.localizedDescription)"
            NSLog("MacFan: 保存配置失败: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            profiles = [.quiet, .performance, .maxSpeed]
            save()
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            profiles = []
            activeProfileID = nil
            loadError = "读取配置失败，原文件未被修改: \(error.localizedDescription)"
            return
        }

        do {
            let decoded = try JSONDecoder().decode(SaveData.self, from: data)
            profiles = decoded.profiles
            if let id = decoded.activeProfileID, profiles.contains(where: { $0.id == id }) {
                activeProfileID = id
            } else {
                activeProfileID = nil
            }
            loadError = nil
        } catch {
            recoverCorruptFile(decodingError: error)
        }
    }

    private func recoverCorruptFile(decodingError: Error) {
        let backupURL = fileURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString).json")
        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
        } catch {
            profiles = []
            activeProfileID = nil
            loadError = "配置已损坏且无法备份，原文件未被覆盖: \(error.localizedDescription)"
            return
        }

        profiles = [.quiet, .performance, .maxSpeed]
        activeProfileID = nil
        loadError = "配置已损坏，原文件已备份为 \(backupURL.lastPathComponent)，并已恢复默认配置。"

        let preservedLoadError = loadError
        save()
        loadError = preservedLoadError
        NSLog("MacFan: 配置解码失败: \(decodingError)")
    }

    private struct SaveData: Codable {
        var profiles: [FanProfile]
        var activeProfileID: UUID?
    }

    // MARK: - 配置评估

    /// 上次匹配到的规则索引（用于迟滞判断）
    private var lastMatchedRuleIndex: Int?

    /// 根据当前温度和电池状态评估配置，返回目标转速百分比 (0-100)，nil = 自动
    public func evaluateActiveProfile(
        maxTemp: Double,
        battery: BatteryInfo,
        hysteresis: Double = 3.0
    ) -> Double? {
        guard let profile = activeProfile, profile.isEnabled else {
            resetEvaluationState()
            return nil
        }

        // 检查触发条件
        switch profile.condition {
        case .always:
            break
        case .charging:
            guard battery.isCharging else {
                resetEvaluationState()
                return nil
            }
        case .onBattery:
            guard battery.isPresent, !battery.isPluggedIn else {
                resetEvaluationState()
                return nil
            }
        case .batteryBelow(let threshold):
            guard battery.isPresent, battery.percentage < threshold else {
                resetEvaluationState()
                return nil
            }
        }

        // 按温度阈值从高到低排序
        let sortedRules = profile.rules.sorted { $0.tempThreshold > $1.tempThreshold }

        // 带迟滞的匹配：温度上升时用阈值，温度下降时用 阈值-hysteresis
        for (index, rule) in sortedRules.enumerated() {
            let effectiveThreshold: Double
            if let lastIndex = lastMatchedRuleIndex, index >= lastIndex {
                // 温度在下降方向，使用迟滞
                effectiveThreshold = rule.tempThreshold - hysteresis
            } else {
                effectiveThreshold = rule.tempThreshold
            }

            if maxTemp >= effectiveThreshold {
                lastMatchedRuleIndex = index
                return rule.fanSpeedPercent
            }
        }

        // 没有匹配的规则，返回自动
        resetEvaluationState()
        return nil
    }
}
