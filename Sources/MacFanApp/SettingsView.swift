import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var monitor: FanMonitor
    @ObservedObject var helper: HelperController
    let onHelperResult: (Bool, String) -> Void

    @AppStorage("refreshInterval") private var refreshInterval: Double = 2.0
    @AppStorage("showTempInMenuBar") private var showTempInMenuBar: Bool = false
    @AppStorage("autoRestoreOnQuit") private var autoRestoreOnQuit: Bool = true
    @State private var launchAtLogin = false
    @State private var loginItemNote: String?
    @State private var confirmUninstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                SettingToggle(title: "Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginItemNote {
                    Text(loginItemNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingToggle(title: "Show temperature in menu bar", isOn: $showTempInMenuBar)
                SettingToggle(title: "Return fans to system control on quit", isOn: $autoRestoreOnQuit)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Refresh interval")
                    .foregroundStyle(.secondary)
                Picker("Refresh interval", selection: $refreshInterval) {
                    Text("1s").tag(1.0)
                    Text("2s").tag(2.0)
                    Text("5s").tag(5.0)
                    Text("10s").tag(10.0)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .onChange(of: refreshInterval) { newValue in
                monitor.updateInterval(newValue)
            }

            Divider()

            helperSection

            Divider()

            HStack {
                Text("MacFan \(Self.appVersion)")
                    .font(.caption.weight(.medium))
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/ryusaksun/macfan")!)
                    .font(.caption)
            }
        }
        .controlSize(.small)
        .padding(16)
        .frame(width: 290)
        .onAppear(perform: refreshLoginItem)
    }

    @ViewBuilder
    private var helperSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Privileged helper")
                Spacer()
                Text(helperStatusText)
                    .foregroundStyle(.secondary)
            }
            if confirmUninstall {
                Text("Fans return to system control and MacFan can no longer change their speed until you reinstall.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { confirmUninstall = false }
                    Button("Uninstall", role: .destructive, action: uninstallHelper)
                }
            } else {
                HStack {
                    Button(helper.status == .installed ? "Reinstall" : "Install") {
                        helper.install(completion: onHelperResult)
                    }
                    if helper.status == .installed || helper.status == .outdated {
                        Button("Uninstall…") { confirmUninstall = true }
                    }
                    if helper.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .disabled(helper.isWorking)
            }
        }
    }

    private var helperStatusText: String {
        switch helper.status {
        case .checking: return "Checking…"
        case .notInstalled: return "Not installed"
        case .outdated: return "Needs update"
        case .installed: return "Installed"
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private func uninstallHelper() {
        confirmUninstall = false
        // 先恢复系统控制，否则卸载后风扇会停留在当前的手动转速
        monitor.restoreSystemControl { _ in
            helper.uninstall(completion: onHelperResult)
        }
    }

    private func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        loginItemNote = status == .requiresApproval
            ? "Approve MacFan in System Settings › General › Login Items."
            : nil
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLoginItem()
        } catch {
            refreshLoginItem()
            loginItemNote = "Couldn't update login item: \(error.localizedDescription)"
        }
    }
}

/// 标签在左、开关右对齐
private struct SettingToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}
