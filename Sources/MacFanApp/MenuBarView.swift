import SwiftUI

struct MenuBarView: View {
    @ObservedObject var monitor: FanMonitor
    @ObservedObject var profileManager: ProfileManager
    @State private var showSettings = false
    @State private var editingProfile: FanProfile?
    @State private var helperInstalled = HelperInstaller.isInstalled
    @State private var controlMessage: String?
    @State private var controlError: String?

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Image(systemName: "fan.fill")
                    .foregroundStyle(.secondary)
                Text("MacFan")
                    .font(.headline)
                Spacer()
                // 电池状态
                if monitor.battery.isPresent {
                    HStack(spacing: 2) {
                        Image(systemName: batteryIcon)
                            .font(.caption2)
                        Text("\(monitor.battery.percentage)%")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                if monitor.maxTemp > 0 {
                    Text("\(Int(monitor.maxTemp))°C")
                        .font(.caption)
                        .foregroundStyle(tempColor(monitor.maxTemp))
                        .fontWeight(.medium)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    // 风扇控制区域
                    if !monitor.fans.isEmpty {
                        SectionHeader(title: "Fans", icon: "fan.fill")

                        // 快捷控制
                        HStack(spacing: 8) {
                            ControlButton(title: "Auto", icon: "arrow.counterclockwise", color: .green) {
                                profileManager.setActive(nil)
                                monitor.resetAllFans()
                            }
                            ControlButton(title: "Max", icon: "flame.fill", color: .red) {
                                profileManager.setActive(nil)
                                monitor.setAllFansMax()
                            }
                        }

                        ForEach(monitor.fans) { fan in
                            FanControlRow(fan: fan, monitor: monitor, profileManager: profileManager)
                        }

                        // 状态消息
                        if let error = monitor.controlError {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.caption2)
                                    .foregroundColor(.red)
                            }
                        } else if let msg = monitor.controlMessage {
                            Text(msg)
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }

                    // 配置方案
                    SectionHeader(title: "Profiles", icon: "list.bullet")

                    ForEach(profileManager.profiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isActive: profileManager.activeProfileID == profile.id,
                            onActivate: {
                                if profileManager.activeProfileID == profile.id {
                                    profileManager.setActive(nil)
                                    monitor.clearProfileState()
                                    monitor.resetAllFans()
                                } else {
                                    profileManager.setActive(profile.id)
                                    monitor.clearProfileState()
                                    // 立即评估并应用
                                    if let pct = profileManager.evaluateActiveProfile(
                                        maxTemp: monitor.maxTemp, battery: monitor.battery
                                    ) {
                                        if pct >= 100 {
                                            monitor.setAllFansMax()
                                        } else {
                                            for fan in monitor.fans {
                                                let rpm = fan.minRPM + (fan.maxRPM - fan.minRPM) * pct / 100.0
                                                monitor.setFanSpeed(fanID: fan.id, rpm: rpm)
                                            }
                                        }
                                    } else {
                                        // 当前温度未匹配任何规则 → 恢复自动
                                        monitor.resetAllFans()
                                    }
                                }
                            },
                            onEdit: {
                                editingProfile = profile
                            },
                            onDelete: {
                                profileManager.deleteProfile(profile.id)
                            }
                        )
                    }

                    Button {
                        var newProfile = FanProfile()
                        newProfile.name = "Custom"
                        profileManager.addProfile(newProfile)
                        editingProfile = newProfile
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                                .font(.caption)
                            Text("New Profile")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)

                    // 温度区域
                    if !monitor.temperatures.isEmpty {
                        SectionHeader(title: "Temperatures", icon: "thermometer.medium")

                        let grouped = Dictionary(grouping: monitor.temperatures) { $0.category }
                        let sortedCategories = TempInfo.TempCategory.allCases.filter { grouped[$0] != nil }

                        ForEach(sortedCategories, id: \.self) { category in
                            if let temps = grouped[category] {
                                CategoryHeader(title: category.rawValue)
                                ForEach(temps) { temp in
                                    TempRowView(temp: temp)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(height: 600)

            Divider()

            // 底部
            if !helperInstalled {
                Button {
                    let result = HelperInstaller.install()
                    if result.success {
                        helperInstalled = true
                        controlMessage = result.message
                    } else {
                        controlError = result.message
                    }
                } label: {
                    HStack {
                        Image(systemName: "lock.shield")
                        Text("Install Helper (one-time setup)")
                    }
                    .font(.caption)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }

            HStack {
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gear")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showSettings) {
                    SettingsView()
                }

                if helperInstalled {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                }

                Spacer()

                Button("Quit") {
                    monitor.resetAllFans()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        monitor.stop()
                        NSApplication.shared.terminate(nil)
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
        .onAppear {
            monitor.start()
        }
        .onDisappear {
            monitor.stop()
        }
        .onChange(of: editingProfile) { profile in
            if let profile {
                openProfileEditor(profile)
                editingProfile = nil
            }
        }
    }

    private func openProfileEditor(_ profile: FanProfile) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Edit Profile"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()

        let editView = ProfileEditView(
            profile: profile,
            onSave: { updated in self.profileManager.updateProfile(updated) },
            onDismiss: { panel.close() }
        )

        panel.contentView = NSHostingView(rootView: editView)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func tempColor(_ temp: Double) -> Color {
        switch temp {
        case ..<40: return .green
        case ..<60: return .yellow
        case ..<80: return .orange
        default: return .red
        }
    }

    private var batteryIcon: String {
        let b = monitor.battery
        if b.isCharging { return "battery.100percent.bolt" }
        switch b.percentage {
        case 75...: return "battery.100percent"
        case 50...: return "battery.75percent"
        case 25...: return "battery.50percent"
        default: return "battery.25percent"
        }
    }
}

// MARK: - Profile Row

struct ProfileRow: View {
    let profile: FanProfile
    let isActive: Bool
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onActivate) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isActive ? .green : .secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)

            Text(profile.name)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            conditionBadge

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.7))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isActive ? Color.green.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var conditionBadge: some View {
        switch profile.condition {
        case .always:
            EmptyView()
        case .charging:
            Image(systemName: "bolt.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
        case .onBattery:
            Image(systemName: "battery.50percent")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .batteryBelow(let pct):
            Text("<\(pct)%")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Fan Control Row

struct FanControlRow: View {
    let fan: FanInfo
    @ObservedObject var monitor: FanMonitor
    @ObservedObject var profileManager: ProfileManager
    @State private var targetRPM: Double = 0
    @State private var isManual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: fan.isStopped ? "fan" : "fan.fill")
                    .foregroundColor(fan.isStopped ? .secondary : .blue)
                Text("Fan \(fan.id)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text(fan.isStopped ? "Stopped" : "\(Int(fan.actualRPM)) RPM")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(fan.isStopped ? .secondary : .primary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fanBarColor(fan.percent))
                        .frame(width: geo.size.width * CGFloat(fan.percent / 100))
                }
            }
            .frame(height: 4)

            if isManual {
                VStack(spacing: 2) {
                    Slider(value: $targetRPM, in: fan.minRPM...fan.maxRPM, step: 100) {
                        Text("RPM")
                    } onEditingChanged: { editing in
                        if !editing {
                            profileManager.setActive(nil)
                            monitor.setFanSpeed(fanID: fan.id, rpm: targetRPM)
                        }
                    }
                    HStack {
                        Text("\(Int(fan.minRPM))")
                        Spacer()
                        Text("Target: \(Int(targetRPM)) RPM")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(Int(fan.maxRPM))")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("\(Int(fan.minRPM))")
                    Spacer()
                    Text("\(Int(fan.percent))%")
                    Spacer()
                    Text("\(Int(fan.maxRPM))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(isManual ? "Auto" : "Manual") {
                    isManual.toggle()
                    if isManual {
                        targetRPM = Swift.max(fan.actualRPM, fan.minRPM)
                    } else {
                        monitor.resetAllFans()
                    }
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func fanBarColor(_ percent: Double) -> Color {
        switch percent {
        case ..<30: return .green
        case ..<60: return .yellow
        case ..<80: return .orange
        default: return .red
        }
    }
}

// MARK: - Temp Row

struct TempRowView: View {
    let temp: TempInfo

    var body: some View {
        HStack {
            Circle()
                .fill(tempColor(temp.value))
                .frame(width: 6, height: 6)
            Text(temp.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(String(format: "%.1f°C", temp.value))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(tempColor(temp.value))
                .fontWeight(.medium)
        }
    }

    private func tempColor(_ temp: Double) -> Color {
        switch temp {
        case ..<40: return .green
        case ..<60: return .yellow
        case ..<80: return .orange
        default: return .red
        }
    }
}

// MARK: - Helpers

struct ControlButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .foregroundColor(color)
        }
        .buttonStyle(.plain)
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.caption)
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

struct CategoryHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fontWeight(.medium)
            Spacer()
        }
        .padding(.top, 2)
    }
}
