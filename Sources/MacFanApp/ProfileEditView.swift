import SwiftUI

/// 在浮动面板中打开配置方案编辑器
@MainActor
final class ProfileEditorController {
    private let profileManager: ProfileManager
    private let monitor: FanMonitor
    private var panel: NSPanel?

    init(profileManager: ProfileManager, monitor: FanMonitor) {
        self.profileManager = profileManager
        self.monitor = monitor
    }

    func open(_ profile: FanProfile, isNew: Bool) {
        panel?.close()

        let editView = ProfileEditView(
            profile: profile,
            isNew: isNew,
            onSave: { [weak self] updated in
                self?.save(updated)
                self?.close()
            },
            onCancel: { [weak self] in
                self?.close()
            }
        )

        let hosting = NSHostingController(rootView: editView)
        hosting.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.title = isNew ? "New Profile" : "Edit Profile"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    private func save(_ profile: FanProfile) {
        profileManager.upsertProfile(profile)
        if profileManager.activeProfileID == profile.id {
            // 编辑正在使用的方案后立即按新规则生效
            monitor.profileDidChange()
        }
    }

    private func close() {
        panel?.close()
        panel = nil
    }
}

struct ProfileEditView: View {
    @State private var profile: FanProfile
    let isNew: Bool
    let onSave: (FanProfile) -> Void
    let onCancel: () -> Void

    private static let batteryThresholds = [10, 20, 30, 40, 50, 60, 70, 80]

    init(profile: FanProfile, isNew: Bool, onSave: @escaping (FanProfile) -> Void, onCancel: @escaping () -> Void) {
        _profile = State(initialValue: profile)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    TextField("Profile name", text: $profile.name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Active when")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Picker("Active when", selection: conditionKind) {
                            Text("Always").tag(0)
                            Text("Charging").tag(1)
                            Text("On Battery").tag(2)
                            Text("Battery Below").tag(3)
                        }
                        .labelsHidden()
                        .fixedSize()

                        if case .batteryBelow = profile.condition {
                            Picker("Battery threshold", selection: batteryThreshold) {
                                ForEach(Self.batteryThresholds, id: \.self) { value in
                                    Text("\(value)%").tag(value)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("Rules")
                    .font(.headline)
                Spacer()
                Button {
                    addRule()
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .controlSize(.small)
            }

            Text("The rule with the highest matching temperature wins. Below every threshold, macOS controls the fans. Speed is a percentage of each fan's range.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if profile.rules.isEmpty {
                Text("No rules — the fans stay under system control.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(.quaternary)
                    )
            } else {
                VStack(spacing: 6) {
                    ForEach($profile.rules) { $rule in
                        RuleRow(rule: $rule) {
                            let id = rule.id
                            withAnimation { profile.rules.removeAll { $0.id == id } }
                        }
                    }
                }
            }

            if let warning = validationWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var trimmedName: String {
        profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationWarning: String? {
        let thresholds = profile.rules.map { $0.tempThreshold.rounded() }
        if Set(thresholds).count != thresholds.count {
            return "Two rules share the same temperature; only one of them will be used."
        }
        let sorted = profile.rules.sorted { $0.tempThreshold < $1.tempThreshold }
        let isMonotonic = zip(sorted, sorted.dropFirst()).allSatisfy { $0.fanSpeedPercent <= $1.fanSpeedPercent }
        if !isMonotonic {
            return "A higher temperature uses a lower speed than a cooler rule. Is that intended?"
        }
        return nil
    }

    private func addRule() {
        let hottest = profile.rules.max { $0.tempThreshold < $1.tempThreshold }
        let rule = hottest.map {
            FanRule(tempThreshold: min(110, $0.tempThreshold + 10), fanSpeedPercent: min(100, $0.fanSpeedPercent + 20))
        } ?? FanRule(tempThreshold: 60, fanSpeedPercent: 50)
        withAnimation { profile.rules.insert(rule, at: 0) }
    }

    private func commit() {
        // 结束文本框编辑：macOS 上点击按钮不会让文本框失去焦点，最后输入的数值可能还没写回
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async {
            var result = profile
            result.name = trimmedName
            result.isEnabled = true
            result.rules = result.rules
                .map { rule in
                    var rule = rule
                    rule.tempThreshold = min(130, max(0, rule.tempThreshold.rounded()))
                    rule.fanSpeedPercent = min(100, max(0, rule.fanSpeedPercent.rounded()))
                    return rule
                }
                .sorted { $0.tempThreshold > $1.tempThreshold }
            onSave(result)
        }
    }

    private var conditionKind: Binding<Int> {
        Binding(
            get: {
                switch profile.condition {
                case .always: return 0
                case .charging: return 1
                case .onBattery: return 2
                case .batteryBelow: return 3
                }
            },
            set: { value in
                switch value {
                case 1: profile.condition = .charging
                case 2: profile.condition = .onBattery
                case 3: profile.condition = .batteryBelow(20)
                default: profile.condition = .always
                }
            }
        )
    }

    private var batteryThreshold: Binding<Int> {
        Binding(
            get: {
                if case .batteryBelow(let pct) = profile.condition { return pct }
                return 20
            },
            set: { profile.condition = .batteryBelow($0) }
        )
    }
}

struct RuleRow: View {
    @Binding var rule: FanRule
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("≥")
                .foregroundStyle(.secondary)
            TextField("Temperature", value: $rule.tempThreshold, format: .number.precision(.fractionLength(0)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
            Stepper("Temperature", value: $rule.tempThreshold, in: 0...110, step: 1)
                .labelsHidden()
            Text("°C")
                .foregroundStyle(.secondary)

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)

            Slider(value: $rule.fanSpeedPercent, in: 0...100) { editing in
                if !editing {
                    rule.fanSpeedPercent = (rule.fanSpeedPercent / 5).rounded() * 5
                }
            }
                .controlSize(.small)
                .tint(Palette.fanLevel(rule.fanSpeedPercent))
            Text(Format.percent(rule.fanSpeedPercent))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove rule")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}
