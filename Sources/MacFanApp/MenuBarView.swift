import SwiftUI

struct MenuBarView: View {
    @ObservedObject var monitor: FanMonitor
    @ObservedObject var profileManager: ProfileManager
    @ObservedObject var helper: HelperController
    let editor: ProfileEditorController

    @State private var showSettings = false
    @State private var contentHeight: CGFloat = 0
    @State private var deletedProfile: DeletedProfile?
    @AppStorage("expandedTemperatureGroups") private var expandedGroupsRaw = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = monitor.lastError {
                        Banner(message: "Cannot read sensors: \(error)", style: .error)
                    }
                    fanSection
                    profileSection
                    if !monitor.temperatures.isEmpty {
                        temperatureSection
                    }
                }
                .padding(14)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .frame(height: scrollHeight)
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            Divider()
            footer
        }
        .frame(width: 340)
        .onAppear { helper.refresh() }
    }

    /// 内容较少时收缩，较多时滚动；上限不超过屏幕可用高度
    private var scrollHeight: CGFloat {
        let screenLimit = (NSScreen.main?.visibleFrame.height ?? 900) - 140
        let limit = min(640, max(320, screenLimit))
        return min(max(contentHeight, 120), limit)
    }

    // MARK: - 标题栏

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Palette.mode(monitor.controlMode).opacity(0.16))
                Image(systemName: "fan.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.mode(monitor.controlMode))
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("MacFan")
                    .font(.headline)
                Text(modeSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                if monitor.maxTemp > 0 {
                    Text(Format.temperature(monitor.maxTemp))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.temperatureText(monitor.maxTemp))
                        .help("Highest sensor temperature")
                }
                if monitor.battery.isPresent {
                    HStack(spacing: 3) {
                        Image(systemName: batteryIcon)
                        Text("\(monitor.battery.percentage)%")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var modeSummary: String {
        switch monitor.controlMode {
        case .system:
            return "System controlled"
        case .manual(let percent):
            return "Manual · \(Format.percent(percent))"
        case .profile(let percent):
            let name = profileManager.activeProfile?.name ?? "Profile"
            return "\(name) · \(percent.map(Format.percent) ?? "auto")"
        }
    }

    private var batteryIcon: String {
        let battery = monitor.battery
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.percentage {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    // MARK: - 风扇

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Fans") {
                if monitor.isApplying {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            VStack(spacing: 10) {
                if monitor.fans.isEmpty {
                    Text(monitor.isConnected ? "No fans detected on this Mac" : "Fan data unavailable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                } else {
                    ForEach(monitor.fans) { fan in
                        FanRow(fan: fan)
                    }
                    Divider()
                    if helper.canControlFans {
                        SpeedControl(monitor: monitor, profileName: profileManager.activeProfile?.name)
                    } else {
                        HelperPrompt(helper: helper, onResult: showResult)
                    }
                }
            }
            .card()

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

    // MARK: - 配置方案

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Profiles") {
                Button {
                    editor.open(.newTemplate, isNew: true)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderless)
                .help("New Profile")
            }

            if let error = profileManager.loadError ?? profileManager.saveError {
                Banner(message: error, style: .warning)
            }

            if let deleted = deletedProfile {
                Banner(
                    message: "Deleted “\(deleted.profile.name)”",
                    style: .info,
                    actionTitle: "Undo",
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

            VStack(spacing: 2) {
                if profileManager.profiles.isEmpty {
                    Text("No profiles yet. Click + to create one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
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
            .card(padding: 4)
        }
    }

    private var activeProfileStatus: String? {
        guard case .profile(let percent) = monitor.controlMode else { return nil }
        return percent.map(Format.percent) ?? "Auto"
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

    // MARK: - 温度

    private var temperatureSection: some View {
        let grouped = Dictionary(grouping: monitor.temperatures, by: \.category)
        let categories = TempInfo.TempCategory.allCases.filter { grouped[$0] != nil }
        let expandable = categories.filter { (grouped[$0]?.count ?? 0) > 1 }
        let allExpanded = !expandable.isEmpty && expandable.allSatisfy(expandedGroups.contains)

        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Temperatures") {
                if !expandable.isEmpty {
                    Button(allExpanded ? "Collapse All" : "Expand All") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            setExpanded(allExpanded ? [] : Set(expandable))
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            VStack(spacing: 0) {
                ForEach(categories, id: \.self) { category in
                    TemperatureGroup(
                        category: category,
                        temps: grouped[category] ?? [],
                        isExpanded: expansionBinding(for: category)
                    )
                    if category != categories.last {
                        Divider()
                            .padding(.leading, 34)
                    }
                }
            }
            .card(padding: 4)
        }
    }

    private var expandedGroups: Set<TempInfo.TempCategory> {
        Set(expandedGroupsRaw.split(separator: ",").compactMap { TempInfo.TempCategory(rawValue: String($0)) })
    }

    private func setExpanded(_ groups: Set<TempInfo.TempCategory>) {
        expandedGroupsRaw = groups.map(\.rawValue).sorted().joined(separator: ",")
    }

    private func expansionBinding(for category: TempInfo.TempCategory) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(category) },
            set: { expanded in
                var groups = expandedGroups
                if expanded {
                    groups.insert(category)
                } else {
                    groups.remove(category)
                }
                setExpanded(groups)
            }
        )
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsView(monitor: monitor, helper: helper, onHelperResult: showResult)
            }

            helperStatusLabel

            Spacer()

            Button("Quit MacFan") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .keyboardShortcut("q")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var helperStatusLabel: some View {
        switch helper.status {
        case .installed:
            Label("Helper ready", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .outdated:
            Label("Helper outdated", systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .notInstalled:
            Label("Helper not installed", systemImage: "lock.shield")
                .font(.caption)
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
            name: "New Profile",
            rules: [
                FanRule(tempThreshold: 75, fanSpeedPercent: 80),
                FanRule(tempThreshold: 60, fanSpeedPercent: 40),
            ]
        )
    }
}

// MARK: - 风扇行

struct FanRow: View {
    let fan: FanInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: fan.isStopped ? "fan" : "fan.fill")
                .font(.system(size: 12))
                .foregroundStyle(fan.isStopped ? Color.secondary : Color.accentColor)
                .frame(width: 14)
            Text("Fan \(fan.id + 1)")
                .font(.callout)
                .frame(width: 44, alignment: .leading)
            LevelBar(fraction: fan.percent / 100, color: Palette.fanLevel(fan.percent))
            Text(fan.isStopped ? "Off" : "\(Int(fan.actualRPM)) RPM")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(fan.isStopped ? .secondary : .primary)
                .frame(width: 76, alignment: .trailing)
        }
        .help("Range \(Int(fan.minRPM))–\(Int(fan.maxRPM)) RPM · Target \(Int(fan.targetRPM)) RPM · \(fan.isManual ? "Manual" : "Automatic")")
    }
}

// MARK: - 转速控制

struct SpeedControl: View {
    @ObservedObject var monitor: FanMonitor
    let profileName: String?

    @State private var sliderValue: Double = 0
    @State private var isDragging = false

    private let presets: [Double] = [0, 25, 50, 75, 100]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Speed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(isDragging || monitor.isApplying ? sliderValue : displayPercent))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }

            // 不使用 step：macOS 会为每一档绘制刻度，101 个刻度挤成一条虚线
            Slider(value: $sliderValue, in: 0...100) { editing in
                isDragging = editing
                if !editing {
                    sliderValue = sliderValue.rounded()
                    monitor.setAllFans(percent: sliderValue)
                }
            }
            .controlSize(.small)
            .tint(Palette.fanLevel(sliderValue))

            HStack(spacing: 4) {
                PresetButton(title: "Auto", isSelected: monitor.controlMode == .system) {
                    monitor.restoreSystemControl()
                }
                .help("Let macOS control the fans")
                ForEach(presets, id: \.self) { preset in
                    PresetButton(
                        title: preset == 100 ? "Max" : Format.percent(preset),
                        isSelected: isManual(at: preset)
                    ) {
                        sliderValue = preset
                        monitor.setAllFans(percent: preset)
                    }
                }
            }

            if let profileName {
                Text("“\(profileName)” is controlling the fans. Picking a speed switches to manual.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

struct PresetButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.primary.opacity(isHovering ? 0.12 : 0.07))
        )
        .onHover { isHovering = $0 }
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
                Text("Checking helper…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        case .notInstalled, .outdated:
            let isUpdate = helper.status == .outdated
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    isUpdate ? "Helper update required" : "One-time setup",
                    systemImage: isUpdate ? "arrow.triangle.2.circlepath" : "lock.shield"
                )
                .font(.callout.weight(.semibold))
                Text(isUpdate
                     ? "MacFan was updated. Reinstall the helper so it matches this version."
                     : "Changing fan speed needs a small privileged helper. You'll enter your password once.")
                    .font(.caption)
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
                        Text(isUpdate ? "Update Helper" : "Install Helper")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(helper.isWorking)
            }
        case .installed:
            EmptyView()
        }
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
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.6))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(profile.name)
                        .font(.callout.weight(isActive ? .semibold : .regular))
                        .lineLimit(1)
                    if let label = profile.condition.label {
                        Pill(text: label, icon: profile.condition.icon)
                    }
                    if let status {
                        Pill(text: status, color: .accentColor)
                            .help(status == "Auto"
                                  ? "No rule matches right now, so macOS controls the fans"
                                  : "Current fan speed set by this profile")
                    }
                }
                Text(profile.ruleSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering ? 1 : 0.45)
            .help("More")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
        .contextMenu { menuItems }
        .help(isActive ? "Click to stop using this profile" : "Click to use this profile")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Edit…", action: onEdit)
        Button("Duplicate", action: onDuplicate)
        Divider()
        Button("Delete", role: .destructive, action: onDelete)
    }
}

// MARK: - 温度分组

struct TemperatureGroup: View {
    let category: TempInfo.TempCategory
    let temps: [TempInfo]
    @Binding var isExpanded: Bool

    private var hottest: TempInfo? { temps.max { $0.value < $1.value } }
    private var isExpandable: Bool { temps.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                guard isExpandable else { return }
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 8)
                        .opacity(isExpandable ? 1 : 0)
                    Image(systemName: category.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(category.rawValue)
                        .font(.callout)
                    if isExpandable {
                        Text("\(temps.count)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if let only = temps.first {
                        Text(only.name)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let hottest {
                        TemperatureValue(value: hottest.value, emphasized: true)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded && isExpandable {
                VStack(spacing: 0) {
                    ForEach(temps) { temp in
                        HStack(spacing: 8) {
                            Text(temp.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            TemperatureValue(value: temp.value, emphasized: false)
                        }
                        .padding(.leading, 42)
                        .padding(.trailing, 8)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

struct TemperatureValue: View {
    let value: Double
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Palette.temperature(value))
                .frame(width: 6, height: 6)
            Text(Format.temperature(value, decimals: true))
                .font(emphasized ? .callout.weight(.medium) : .subheadline)
                .monospacedDigit()
                .foregroundStyle(Palette.temperatureText(value))
        }
    }
}
