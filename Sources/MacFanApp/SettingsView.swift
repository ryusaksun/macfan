import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var monitor: FanMonitor
    @AppStorage("refreshInterval") private var refreshInterval: Double = 2.0
    @AppStorage("showTempInMenuBar") private var showTempInMenuBar: Bool = false
    @AppStorage("autoRestoreOnQuit") private var autoRestoreOnQuit: Bool = true
    @State private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.headline)

            // 开机自启
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    launchAtLogin = newValue
                    setLaunchAtLogin(newValue)
                }
            ))
                .font(.caption)

            // 刷新间隔
            HStack {
                Text("Refresh Interval")
                    .font(.caption)
                Picker("", selection: $refreshInterval) {
                    Text("1s").tag(1.0)
                    Text("2s").tag(2.0)
                    Text("5s").tag(5.0)
                    Text("10s").tag(10.0)
                }
                .labelsHidden()
                .frame(width: 80)
            }
            .onChange(of: refreshInterval) { newValue in
                monitor.updateInterval(newValue)
            }

            // 菜单栏显示温度
            Toggle("Show temperature in menu bar", isOn: $showTempInMenuBar)
                .font(.caption)

            // 退出时恢复
            Toggle("Restore auto mode on quit", isOn: $autoRestoreOnQuit)
                .font(.caption)

            Divider()

            // 关于
            VStack(alignment: .leading, spacing: 4) {
                Text("MacFan v1.0.0")
                    .font(.caption)
                    .fontWeight(.medium)
                Text("macOS fan control for Apple Silicon")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 260)
        .onAppear {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enabled // 回滚
        }
    }
}
