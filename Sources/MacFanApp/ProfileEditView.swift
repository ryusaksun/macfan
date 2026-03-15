import SwiftUI

struct ProfileEditView: View {
    @State var profile: FanProfile
    var onSave: (FanProfile) -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // 名称
            HStack {
                Text("Name")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                TextField("Profile name", text: $profile.name)
                    .textFieldStyle(.roundedBorder)
            }

            // 条件
            HStack {
                Text("When")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: conditionBinding) {
                    Text("Always").tag(0)
                    Text("Charging").tag(1)
                    Text("On Battery").tag(2)
                    Text("Battery < 20%").tag(3)
                }
                .labelsHidden()
            }

            Divider()

            // 规则列表
            HStack {
                Text("Rules")
                    .font(.headline)
                Spacer()
                Button {
                    profile.rules.append(FanRule(tempThreshold: 60, fanSpeedPercent: 50))
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
            }

            if profile.rules.isEmpty {
                Text("No rules — fan will stay in auto mode")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(profile.rules.enumerated()), id: \.element.id) { index, _ in
                            RuleRow(rule: $profile.rules[index]) {
                                profile.rules.remove(at: index)
                            }
                        }
                    }
                }
            }

            Spacer()

            HStack {
                Toggle("Enabled", isOn: $profile.isEnabled)
                    .font(.caption)
                Spacer()
                Button("Done") {
                    onSave(profile)
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(20)
    }

    private var conditionBinding: Binding<Int> {
        Binding(
            get: {
                switch profile.condition {
                case .always: return 0
                case .charging: return 1
                case .onBattery: return 2
                case .batteryBelow: return 3
                }
            },
            set: { val in
                switch val {
                case 1: profile.condition = .charging
                case 2: profile.condition = .onBattery
                case 3: profile.condition = .batteryBelow(20)
                default: profile.condition = .always
                }
            }
        )
    }
}

struct RuleRow: View {
    @Binding var rule: FanRule
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Temp ≥")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("", value: $rule.tempThreshold, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
                .onChange(of: rule.tempThreshold) { newValue in
                    rule.tempThreshold = max(0, min(130, newValue))
                }

            Text("°C →")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("", value: $rule.fanSpeedPercent, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
                .onChange(of: rule.fanSpeedPercent) { newValue in
                    rule.fanSpeedPercent = max(0, min(100, newValue))
                }

            Text("%")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
