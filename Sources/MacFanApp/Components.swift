import SwiftUI

// MARK: - 配色

enum Theme {
    static let good = Color(red: 0.32, green: 0.80, blue: 0.50)
    static let warm = Color(red: 0.96, green: 0.74, blue: 0.32)
    static let hot = Color(red: 0.98, green: 0.54, blue: 0.26)
    static let danger = Color(red: 0.96, green: 0.36, blue: 0.32)
    static let cool = Color(red: 0.40, green: 0.64, blue: 0.98)
    static let violet = Color(red: 0.66, green: 0.56, blue: 0.98)
    static let teal = Color(red: 0.38, green: 0.78, blue: 0.80)
    static let accent = Color(red: 0.45, green: 0.62, blue: 1.0)

    static let cardFill = Color.white.opacity(0.055)
    static let cardStroke = Color.white.opacity(0.08)
    static let chipFill = Color.white.opacity(0.08)
    static let track = Color.white.opacity(0.09)

    /// 左上角暖色光晕 + 近黑底色
    static var background: some View {
        ZStack {
            Color(red: 0.075, green: 0.07, blue: 0.065)
            RadialGradient(
                colors: [Color(red: 0.36, green: 0.26, blue: 0.15).opacity(0.85), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 460
            )
        }
    }

    static func temperature(_ value: Double) -> Color {
        switch value {
        case ..<55: return good
        case ..<75: return warm
        case ..<90: return hot
        default: return danger
        }
    }

    static func temperatureStatus(_ value: Double) -> String {
        switch value {
        case ..<55: return "凉爽"
        case ..<75: return "正常"
        case ..<90: return "偏热"
        default: return "过热"
        }
    }

    static func fanLevel(_ percent: Double) -> Color {
        switch percent {
        case ..<30: return good
        case ..<60: return warm
        case ..<80: return hot
        default: return danger
        }
    }

    static func mode(_ mode: FanControlMode) -> Color {
        switch mode {
        case .system: return good
        case .manual: return hot
        case .profile: return accent
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

    static func rpm(_ value: Double) -> String {
        Int(value.rounded()).formatted()
    }

    static func duration(minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        let hours = minutes / 60
        let mins = minutes % 60
        return hours > 0 ? "\(hours) 小时 \(mins) 分" : "\(mins) 分钟"
    }
}

enum SystemInfo {
    /// 例如 "M5 Pro"
    static let chipName: String? = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        let name = String(cString: buffer).replacingOccurrences(of: "Apple ", with: "")
        return name.isEmpty ? nil : name
    }()
}

extension TempInfo.TempCategory {
    var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "内存"
        case .storage: return "存储"
        case .battery: return "电池"
        case .other: return "其他"
        }
    }

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

    var tint: Color {
        switch self {
        case .cpu: return Theme.good
        case .gpu: return Theme.violet
        case .memory: return Theme.warm
        case .storage: return Theme.cool
        case .battery: return Theme.good
        case .other: return Theme.teal
        }
    }
}

extension ProfileCondition {
    var label: String? {
        switch self {
        case .always: return nil
        case .charging: return "充电时"
        case .onBattery: return "电池供电"
        case .batteryBelow(let pct): return "电量 < \(pct)%"
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
        guard !rules.isEmpty else { return "无规则" }
        return rules
            .sorted { $0.tempThreshold < $1.tempThreshold }
            .map { rule in
                rule.tempThreshold <= 0
                    ? "始终 \(Format.percent(rule.fanSpeedPercent))"
                    : "≥\(Int(rule.tempThreshold))° \(Format.percent(rule.fanSpeedPercent))"
            }
            .joined(separator: " · ")
    }
}

// MARK: - 卡片

struct DashCard<Accessory: View, Content: View>: View {
    let icon: String
    let title: String
    var tint: Color = .secondary
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                accessory
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.cardStroke)
        )
    }
}

extension DashCard where Accessory == EmptyView {
    init(icon: String, title: String, tint: Color = .secondary, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.tint = tint
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// 右上角的小标签
struct Chip: View {
    let text: String
    var icon: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(tint ?? Color.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint.map { $0.opacity(0.16) } ?? Theme.chipFill)
        )
    }
}

/// 大号数值 + 小号单位
struct BigValue: View {
    let value: String
    let unit: String
    var size: CGFloat = 26
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: size, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(unit)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 趋势图

/// 根据数据计算显示范围；保证最小跨度，避免微小波动被放大成剧烈起伏
private func displayRange(_ values: [Double], minSpan: Double, floor: Double?) -> ClosedRange<Double> {
    guard let low = values.min(), let high = values.max() else { return 0...1 }
    let mid = (low + high) / 2
    let span = max(minSpan, high - low)
    var lower = mid - span / 2
    if let floor { lower = max(floor, lower) }
    return lower...(lower + span)
}

/// 柱状趋势（最新的在右侧）
struct BarSparkline: View {
    let values: [Double]
    var color: Color
    var minSpan: Double = 20
    var floor: Double? = 0
    var slots = 26

    var body: some View {
        GeometryReader { proxy in
            let recent = Array(values.suffix(slots))
            let padding = slots - recent.count
            let range = displayRange(recent, minSpan: minSpan, floor: floor)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<slots, id: \.self) { index in
                    let value = index >= padding ? recent[index - padding] : nil
                    let fraction = value.map { min(1, max(0, ($0 - range.lowerBound) / (range.upperBound - range.lowerBound))) } ?? 0
                    RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                        .fill(value == nil ? Theme.track : color.opacity(0.45 + 0.55 * fraction))
                        .frame(height: max(2, proxy.size.height * fraction))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 22)
    }
}

/// 面积折线趋势
struct AreaSparkline: View {
    let values: [Double]
    var color: Color
    var minSpan: Double = 10
    var floor: Double?
    var height: CGFloat = 26

    var body: some View {
        GeometryReader { proxy in
            let points = makePoints(in: proxy.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: proxy.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))

                    Path { path in
                        path.addLines(points)
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                } else {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: proxy.size.height - 1))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height - 1))
                    }
                    .stroke(Theme.track, lineWidth: 1)
                }
            }
        }
        .frame(height: height)
    }

    private func makePoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let range = displayRange(values, minSpan: minSpan, floor: floor)
        let step = size.width / CGFloat(MonitorHistory.capacity - 1)
        let startX = size.width - step * CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            return CGPoint(
                x: startX + step * CGFloat(index),
                y: size.height - 2 - (size.height - 4) * CGFloat(min(1, max(0, fraction)))
            )
        }
    }
}

/// 圆环进度
struct RingGauge: View {
    let fraction: Double
    var color: Color
    var icon: String?
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.track, lineWidth: 4)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// 细长进度条
struct LevelBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                if clamped > 0 {
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(proxy.size.height, proxy.size.width * clamped))
                }
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// 分段按钮
struct SegmentButton: View {
    let title: String
    let isSelected: Bool
    var tint: Color = .white
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? tint.opacity(0.2) : Color.white.opacity(isHovering ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? tint.opacity(0.35) : .clear)
        )
        .onHover { isHovering = $0 }
    }
}

/// 状态提示条
struct Banner: View {
    enum Style {
        case error, warning, success, info

        var color: Color {
            switch self {
            case .error: return Theme.danger
            case .warning: return Theme.hot
            case .success: return Theme.good
            case .info: return Theme.accent
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
                    .buttonStyle(.plain)
                    .foregroundStyle(style.color)
                    .fontWeight(.semibold)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(style.color.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style.color.opacity(0.22))
        )
    }
}
