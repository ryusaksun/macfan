import SwiftUI

struct MenuBarView: View {
    @ObservedObject var monitor: FanMonitor
    @ObservedObject var profileManager: ProfileManager
    @ObservedObject var helper: HelperController
    let editor: ProfileEditorController

    @State private var showSettings = false
    @State private var contentHeight: CGFloat = 0
    @State private var deletedProfile: DeletedProfile?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let error = monitor.lastError {
                        Banner(message: "无法读取传感器：\(error)", style: .error)
                    }
                    fanCard
                    controlFeedback
                    sensorGrid
                    profilesCard
                }
                .padding(12)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .frame(height: scrollHeight)
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }

            footer
        }
        .frame(width: 340)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onAppear { helper.refresh() }
    }

    /// 内容较少时收缩，较多时滚动；上限不超过屏幕可用高度
    private var scrollHeight: CGFloat {
        let screenLimit = (NSScreen.main?.visibleFrame.height ?? 900) - 100
        let limit = min(880, max(360, screenLimit))
        return min(max(contentHeight, 160), limit)
    }

    // MARK: - 风扇

    private var fanCard: some View {
        DashCard(icon: "fan.fill", title: "风扇", tint: Theme.cool) {
            if monitor.isApplying {
                ProgressView()
                    .controlSize(.mini)
            }
            if !monitor.fans.isEmpty {
                Chip(text: "转速 \(Format.percent(monitor.averageFanPercent))")
            }
        } content: {
            if monitor.fans.isEmpty {
                Text(monitor.isConnected ? "这台 Mac 没有风扇" : "无法读取风扇数据")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                HStack(alignment: .lastTextBaseline) {
                    BigValue(value: Format.rpm(averageRPM), unit: "RPM")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(monitor.fans) { fan in
                            Text("风扇 \(fan.id + 1)  \(fan.isStopped ? "停转" : Format.rpm(fan.actualRPM))")
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .help("转速范围 \(Format.rpm(fan.minRPM))–\(Format.rpm(fan.maxRPM)) RPM · 目标 \(Format.rpm(fan.targetRPM)) RPM")
                        }
                    }
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(Theme.mode(monitor.controlMode))
                        .frame(width: 6, height: 6)
                    Text(modeDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                AreaSparkline(values: monitor.history.fanRPM, color: Theme.cool, minSpan: 1_500, floor: 0)

                if helper.canControlFans {
                    FanControls(monitor: monitor)
                        .padding(.top, 2)
                } else {
                    HelperPrompt(helper: helper, onResult: showResult)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var averageRPM: Double {
        guard !monitor.fans.isEmpty else { return 0 }
        return monitor.fans.map(\.actualRPM).reduce(0, +) / Double(monitor.fans.count)
    }

    private var modeDescription: String {
        switch monitor.controlMode {
        case .system:
            return "由系统自动调节"
        case .manual(let percent):
            return "手动设定 · \(Format.percent(percent))"
        case .profile(let percent):
            let name = profileManager.activeProfile?.name ?? "配置方案"
            if let percent {
                return "方案「\(name)」· \(Format.percent(percent))"
            }
            return "方案「\(name)」· 未达阈值，由系统调节"
        }
    }

    @ViewBuilder
    private var controlFeedback: some View {
        if let error = monitor.controlError {
            Banner(message: error, style: .error, onDismiss: { monitor.controlError = nil })
        } else if let message = monitor.controlMessage {
            Banner(message: message, style: .success)
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(3))
                    if monitor.controlMessage == message {
                        withAnimation { monitor.controlMessage = nil }
                    }
                }
        }
    }

    private func showResult(success: Bool, message: String) {
        if success {
            monitor.controlMessage = message
            monitor.controlError = nil
        } else {
            monitor.controlError = message
            monitor.controlMessage = nil
        }
    }

    // MARK: - 温度与电池

    private enum SensorTile: Hashable {
        case temperature(TempInfo.TempCategory)
        case battery
    }

    /// 两列卡片，落单的最后一张占满整行。有电池时电池卡片排在"其他"之前，电池温度显示在电池卡片中
    private var sensorGrid: some View {
        let grouped = Dictionary(grouping: monitor.temperatures, by: \.category)
        let tiles = TempInfo.TempCategory.allCases.compactMap { category -> SensorTile? in
            if category == .battery && monitor.battery.isPresent { return .battery }
            return grouped[category] != nil ? .temperature(category) : nil
        }
        let rows = stride(from: 0, to: tiles.count, by: 2).map { Array(tiles[$0..<min($0 + 2, tiles.count)]) }
        return VStack(spacing: 10) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { tile in
                        switch tile {
                        case .temperature(let category):
                            TemperatureCard(
                                category: category,
                                temps: grouped[category] ?? [],
                                history: monitor.history.temperatures[category] ?? []
                            )
                        case .battery:
                            batteryCard
                        }
                    }
                }
                // 同一行的卡片等高
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var batteryCard: some View {
        let battery = monitor.battery
        let batteryTemp = monitor.temperatures.filter { $0.category == .battery }.map(\.value).max()
        return DashCard(
            icon: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent",
            title: "电池",
            tint: Theme.good
        ) {
            if let batteryTemp {
                Chip(text: Format.temperature(batteryTemp, decimals: true))
            }
        } content: {
            BigValue(value: "\(battery.percentage)", unit: "%", size: 22)
            SegmentMeter(fraction: Double(battery.percentage) / 100, color: batteryColor)
            Text(batteryDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 半宽卡片放得下的长度
    private var batteryDescription: String {
        let battery = monitor.battery
        if battery.isPluggedIn {
            guard battery.isCharging else { return "已接电 · 未充电" }
            return Format.duration(minutes: battery.timeToFull).map { "约 \($0)充满" } ?? "已接电 · 充电中"
        }
        return Format.duration(minutes: battery.timeToEmpty).map { "剩余约 \($0)" } ?? "电池供电"
    }

    private var batteryColor: Color {
        switch monitor.battery.percentage {
        case ..<20: return Theme.danger
        case ..<40: return Theme.warm
        default: return Theme.good
        }
    }

    // MARK: - 配置方案

    private var profilesCard: some View {
        DashCard(icon: "slider.horizontal.3", title: "配置方案", tint: Theme.accent) {
            Button {
                editor.open(.newTemplate, isNew: true)
            } label: {
                Chip(text: "新建", icon: "plus")
            }
            .buttonStyle(.plain)
            .help("新建配置方案")
        } content: {
            if let error = profileManager.loadError ?? profileManager.saveError {
                Banner(message: error, style: .warning)
            }

            if let deleted = deletedProfile {
                Banner(
                    message: "已删除「\(deleted.profile.name)」",
                    style: .info,
                    actionTitle: "撤销",
                    action: {
                        profileManager.restoreProfile(deleted.profile, at: deleted.index)
                        deletedProfile = nil
                    },
                    onDismiss: { deletedProfile = nil }
                )
                .task(id: deleted.profile.id) {
                    try? await Task.sleep(for: .seconds(8))
                    if deletedProfile?.profile.id == deleted.profile.id {
                        withAnimation { deletedProfile = nil }
                    }
                }
            }

            if profileManager.profiles.isEmpty {
                Text("还没有配置方案，点击「新建」创建一个。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }

            VStack(spacing: 2) {
                ForEach(profileManager.profiles) { profile in
                    let isActive = profileManager.activeProfileID == profile.id
                    ProfileRow(
                        profile: profile,
                        isActive: isActive,
                        status: isActive ? activeProfileStatus : nil,
                        onToggle: { monitor.activateProfile(isActive ? nil : profile.id) },
                        onEdit: { editor.open(profile, isNew: false) },
                        onDuplicate: { profileManager.duplicateProfile(profile.id) },
                        onDelete: { delete(profile) }
                    )
                }
            }
            .padding(.horizontal, -6)
        }
    }

    private var activeProfileStatus: String? {
        guard case .profile(let percent) = monitor.controlMode else { return nil }
        return percent.map(Format.percent) ?? "待命"
    }

    private func delete(_ profile: FanProfile) {
        guard let removed = profileManager.deleteProfile(profile.id) else { return }
        withAnimation {
            deletedProfile = DeletedProfile(profile: removed.profile, index: removed.index)
        }
        if removed.wasActive {
            // 立即交还系统控制，而不是等下一次定时评估
            monitor.profileDidChange()
        }
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                showSettings.toggle()
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsView(monitor: monitor, helper: helper, onHelperResult: showResult)
            }

            helperStatusLabel

            Spacer()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.22))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var helperStatusLabel: some View {
        switch helper.status {
        case .installed:
            Label("辅助程序就绪", systemImage: "checkmark.shield.fill")
                .foregroundStyle(Theme.good)
        case .outdated:
            Label("辅助程序需更新", systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(Theme.hot)
        case .notInstalled:
            Label("未安装辅助程序", systemImage: "lock.shield")
        case .checking:
            EmptyView()
        }
    }
}

private struct DeletedProfile: Equatable {
    let profile: FanProfile
    let index: Int
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension FanProfile {
    /// 新建配置方案时的起点
    static var newTemplate: FanProfile {
        FanProfile(
            name: "新方案",
            rules: [
                FanRule(tempThreshold: 75, fanSpeedPercent: 80),
                FanRule(tempThreshold: 60, fanSpeedPercent: 40),
            ]
        )
    }
}

// MARK: - 风扇控制

struct FanControls: View {
    @ObservedObject var monitor: FanMonitor

    @State private var sliderValue: Double = 0
    @State private var isDragging = false

    private static let presets: [(title: String, percent: Double)] = [
        ("安静", 25), ("均衡", 50), ("降温", 75), ("强冷", 100),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SegmentButton(title: "自动", isSelected: monitor.controlMode == .system, tint: Theme.good) {
                    monitor.restoreSystemControl()
                }
                .help("交由 macOS 自动控制")
                ForEach(Self.presets, id: \.percent) { preset in
                    SegmentButton(
                        title: preset.title,
                        isSelected: isManual(at: preset.percent),
                        tint: Theme.fanLevel(preset.percent)
                    ) {
                        sliderValue = preset.percent
                        monitor.setAllFans(percent: preset.percent)
                    }
                    .help("所有风扇 \(Format.percent(preset.percent)) 转速")
                }
            }

            HStack(spacing: 10) {
                Text("自定义")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                // 不使用 step：macOS 会为每一档绘制刻度，101 个刻度挤成一条虚线
                Slider(value: $sliderValue, in: 0...100) { editing in
                    isDragging = editing
                    if !editing {
                        sliderValue = sliderValue.rounded()
                        monitor.setAllFans(percent: sliderValue)
                    }
                }
                .controlSize(.mini)
                .tint(Theme.fanLevel(sliderValue))
                Text(Format.percent(isDragging || monitor.isApplying ? sliderValue : displayPercent))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .onAppear(perform: sync)
        .onChange(of: monitor.controlMode) { _ in sync() }
        .onChange(of: monitor.fans) { _ in sync() }
        .onChange(of: monitor.isApplying) { _ in sync() }
    }

    private var displayPercent: Double {
        switch monitor.controlMode {
        case .manual(let percent):
            return percent
        case .profile(let percent?):
            return percent
        default:
            return monitor.averageFanPercent
        }
    }

    private func isManual(at preset: Double) -> Bool {
        guard case .manual(let percent) = monitor.controlMode else { return false }
        return abs(percent - preset) < 0.5
    }

    /// 拖动或请求进行中时保留用户选择的值，其余时间跟随实际状态
    private func sync() {
        guard !isDragging, !monitor.isApplying else { return }
        sliderValue = displayPercent
    }
}

struct HelperPrompt: View {
    @ObservedObject var helper: HelperController
    let onResult: (Bool, String) -> Void

    var body: some View {
        switch helper.status {
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在检查辅助程序…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        case .notInstalled, .outdated:
            let isUpdate = helper.status == .outdated
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: isUpdate ? "arrow.triangle.2.circlepath" : "lock.shield.fill")
                        .foregroundStyle(Theme.warm)
                    Text(isUpdate ? "辅助程序需要更新" : "需要一次性授权")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(isUpdate
                     ? "MacFan 已更新，请重新安装辅助程序以匹配当前版本。"
                     : "调节风扇转速需要安装一个特权辅助程序，只需输入一次密码。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    helper.install(completion: onResult)
                } label: {
                    HStack(spacing: 6) {
                        if helper.isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isUpdate ? "更新辅助程序" : "安装辅助程序")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(helper.isWorking)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.warm.opacity(0.1))
            )
        case .installed:
            EmptyView()
        }
    }
}

// MARK: - 温度卡片

struct TemperatureCard: View {
    let category: TempInfo.TempCategory
    let temps: [TempInfo]
    let history: [Double]

    @State private var showDetails = false

    private var hottest: TempInfo? { temps.max { $0.value < $1.value } }

    var body: some View {
        let value = hottest?.value ?? 0
        let isHot = value >= 75
        DashCard(icon: category.icon, title: category.displayName, tint: category.tint) {
            Chip(text: Theme.temperatureStatus(value), tint: isHot ? Theme.temperature(value) : nil)
        } content: {
            BigValue(
                value: String(format: "%.1f", value),
                unit: "°C",
                size: 22,
                color: isHot ? Theme.temperature(value) : .primary
            )
            if category == .cpu {
                BarSparkline(values: history, color: category.tint, minSpan: 20, floor: nil)
            } else {
                AreaSparkline(values: history, color: category.tint, minSpan: 8, height: 22)
            }
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if temps.count > 1 { showDetails.toggle() }
        }
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            SensorList(category: category, temps: temps)
        }
        .help(temps.count > 1 ? "点击查看全部传感器" : (hottest?.name ?? ""))
    }

    private var caption: String {
        guard let hottest else { return "" }
        return temps.count > 1 ? "\(temps.count) 个传感器 · \(hottest.name)" : hottest.name
    }
}

struct SensorList: View {
    let category: TempInfo.TempCategory
    let temps: [TempInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(category.displayName)传感器")
                .font(.system(size: 12, weight: .semibold))
            ForEach(temps.sorted { $0.value > $1.value }) { temp in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.temperature(temp.value))
                        .frame(width: 6, height: 6)
                    Text(temp.name)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(Format.temperature(temp.value, decimals: true))
                        .monospacedDigit()
                }
                .font(.system(size: 12))
            }
        }
        .padding(12)
        .frame(width: 220)
        .preferredColorScheme(.dark)
    }
}

// MARK: - 配置方案行

struct ProfileRow: View {
    let profile: FanProfile
    let isActive: Bool
    let status: String?
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isActive ? Theme.accent : Color.secondary.opacity(0.5))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                    if let label = profile.condition.label {
                        Chip(text: label, icon: profile.condition.icon)
                    }
                    if let status {
                        Chip(text: status, tint: Theme.accent)
                            .help(status == "待命"
                                  ? "当前温度未达到任何规则，由系统控制风扇"
                                  : "该方案当前设定的风扇转速")
                    }
                }
                Text(profile.ruleSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering ? 1 : 0.45)
            .help("更多操作")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Theme.accent.opacity(0.16) : Color.white.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
        .contextMenu { menuItems }
        .help(isActive ? "点击停用此方案" : "点击启用此方案")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("编辑…", action: onEdit)
        Button("复制", action: onDuplicate)
        Divider()
        Button("删除", role: .destructive, action: onDelete)
    }
}
