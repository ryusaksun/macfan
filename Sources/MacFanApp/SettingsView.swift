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
            Text("设置")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                SettingToggle(title: "开机自动启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginItemNote {
                    Text(loginItemNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingToggle(title: "在菜单栏显示温度", isOn: $showTempInMenuBar)
                SettingToggle(title: "退出时恢复系统控制", isOn: $autoRestoreOnQuit)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("刷新间隔")
                    .foregroundStyle(.secondary)
                Picker("刷新间隔", selection: $refreshInterval) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("5 秒").tag(5.0)
                    Text("10 秒").tag(10.0)
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
        .font(.system(size: 12))
        .padding(16)
        .frame(width: 290)
        .preferredColorScheme(.dark)
        .onAppear(perform: refreshLoginItem)
    }

    @ViewBuilder
    private var helperSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("特权辅助程序")
                Spacer()
                Text(helperStatusText)
                    .foregroundStyle(.secondary)
            }
            if confirmUninstall {
                Text("卸载后风扇恢复系统控制，重新安装前 MacFan 无法调节转速。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("取消") { confirmUninstall = false }
                    Button("卸载", role: .destructive, action: uninstallHelper)
                }
            } else {
                HStack {
                    Button(helper.status == .installed ? "重新安装" : "安装") {
                        helper.install(completion: onHelperResult)
                    }
                    if helper.status == .installed || helper.status == .outdated {
                        Button("卸载…") { confirmUninstall = true }
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
        case .checking: return "检查中…"
        case .notInstalled: return "未安装"
        case .outdated: return "需要更新"
        case .installed: return "已安装"
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
            ? "请在「系统设置 › 通用 › 登录项」中允许 MacFan。"
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
            loginItemNote = "无法更新登录项：\(error.localizedDescription)"
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
