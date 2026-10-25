import SwiftUI

// MARK: - 配色

enum Palette {
    /// 温度指示色（用于圆点等小面积图形）
    static func temperature(_ value: Double) -> Color {
        switch value {
        case ..<55: return .green
        case ..<75: return .yellow
        case ..<90: return .orange
        default: return .red
        }
    }

    /// 温度文字色：黄色文字在浅色模式下难以辨认，正常温度使用主文字色
    static func temperatureText(_ value: Double) -> Color {
        switch value {
        case ..<75: return .primary
        case ..<90: return .orange
        default: return .red
        }
    }

    static func fanLevel(_ percent: Double) -> Color {
        switch percent {
        case ..<30: return .green
        case ..<60: return .yellow
        case ..<80: return .orange
        default: return .red
        }
    }

    static func mode(_ mode: FanControlMode) -> Color {
        switch mode {
        case .system: return .green
        case .manual: return .orange
        case .profile: return .accentColor
        }
    }
}

// MARK: - 格式化

enum Format {
    static func temperature(_ value: Double, decimals: Bool = false) -> String {
        decimals ? String(format: "%.1f°C", value) : "\(Int(value.rounded()))°C"
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

extension TempInfo.TempCategory {
    var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.grid.3x3.fill"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .battery: return "battery.75percent"
        case .other: return "thermometer.medium"
        }
    }
}

extension ProfileCondition {
    var label: String? {
        switch self {
        case .always: return nil
        case .charging: return "Charging"
        case .onBattery: return "On Battery"
        case .batteryBelow(let pct): return "Battery < \(pct)%"
        }
    }

    var icon: String {
        switch self {
        case .always: return "infinity"
        case .charging: return "bolt.fill"
        case .onBattery: return "battery.50percent"
        case .batteryBelow: return "battery.25percent"
        }
    }
}

extension FanProfile {
    /// 例如 "≥60° 30% · ≥70° 60% · ≥80° 100%"
    var ruleSummary: String {
        guard !rules.isEmpty else { return "No rules" }
        return rules
            .sorted { $0.tempThreshold < $1.tempThreshold }
            .map { rule in
                rule.tempThreshold <= 0
                    ? "Always \(Format.percent(rule.fanSpeedPercent))"
                    : "≥\(Int(rule.tempThreshold))° \(Format.percent(rule.fanSpeedPercent))"
            }
            .joined(separator: " · ")
    }
}

// MARK: - 通用视图

struct SectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            accessory
        }
        .padding(.horizontal, 2)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String) {
        self.title = title
        self.accessory = EmptyView()
    }
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            )
    }
}

extension View {
    func card(padding: CGFloat = 10) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// 细长的进度条
struct LevelBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if clamped > 0 {
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(proxy.size.height, proxy.size.width * clamped))
                }
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// 状态提示条
struct Banner: View {
    enum Style {
        case error, warning, success, info

        var color: Color {
            switch self {
            case .error: return .red
            case .warning: return .orange
            case .success: return .green
            case .info: return .accentColor
            }
        }

        var icon: String {
            switch self {
            case .error: return "exclamationmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    let message: String
    var style: Style = .info
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: style.icon)
                .foregroundStyle(style.color)
            Text(message)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(style.color.opacity(0.12))
        )
    }
}

/// 紧凑的胶囊标签
struct Pill: View {
    let text: String
    var icon: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
            }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}
