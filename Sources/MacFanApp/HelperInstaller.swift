import Foundation

enum HelperStatus: Equatable {
    case checking
    case notInstalled
    /// 已安装的二进制与 App 内置的不一致（App 升级后需要重新安装）
    case outdated
    case installed
}

/// 一次性安装特权 Helper 为系统 LaunchDaemon
/// 安装后 Helper 以 root 运行，App 通过 XPC 通信，不再需要密码
enum HelperInstaller {
    static let helperInstallPath = "/Library/PrivilegedHelperTools/com.macfan.helper"
    static let plistInstallPath = "/Library/LaunchDaemons/com.macfan.helper.plist"
    static let serviceLabel = "com.macfan.helper"

    /// 检查 Helper 状态。会启动 launchctl 并比较二进制，请勿在主线程调用。
    static func currentStatus() -> HelperStatus {
        guard FileManager.default.fileExists(atPath: helperInstallPath), isServiceLoaded else {
            return .notInstalled
        }
        guard let bundledHelperPath = findHelperBinary() else {
            return .installed
        }
        // 协议会随 App 更新；二进制不同就要求重新安装，避免新 App 调用旧 XPC selector。
        return FileManager.default.contentsEqual(atPath: helperInstallPath, andPath: bundledHelperPath)
            ? .installed
            : .outdated
    }

    /// 检查 daemon 是否已加载
    private static var isServiceLoaded: Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "system/\(serviceLabel)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 安装 Helper（弹出一次密码框）。NSAppleScript 只能在主线程使用。
    @MainActor
    static func install() -> (success: Bool, message: String) {
        guard let helperSrc = findHelperBinary() else {
            return (false, "找不到 MacFanHelper 二进制")
        }

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(serviceLabel)</string>
            <key>Program</key>
            <string>\(helperInstallPath)</string>
            <key>MachServices</key>
            <dict>
                <key>\(serviceLabel)</key>
                <true/>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        </plist>
        """

        // 先停止旧服务再替换二进制：直接覆盖正在运行的可执行文件会让旧进程因签名失效被杀。
        // bootout 是异步的，紧接着 bootstrap 可能失败，所以重试几次。
        let script = """
        set -e
        HELPER_SRC=\(shellQuoted(helperSrc))
        launchctl bootout system/\(serviceLabel) 2>/dev/null || true
        mkdir -p /Library/PrivilegedHelperTools
        rm -f '\(helperInstallPath)'
        cp "$HELPER_SRC" '\(helperInstallPath)'
        chown root:wheel '\(helperInstallPath)'
        chmod 755 '\(helperInstallPath)'
        cat > '\(plistInstallPath)' << 'PLISTEOF'
        \(plistContent)
        PLISTEOF
        chown root:wheel '\(plistInstallPath)'
        chmod 644 '\(plistInstallPath)'
        for attempt in 1 2 3 4 5; do
            if launchctl bootstrap system '\(plistInstallPath)' 2>/dev/null; then
                echo OK
                exit 0
            fi
            sleep 1
        done
        echo "launchctl bootstrap 失败" >&2
        exit 1
        """

        let result = runPrivileged(
            script: script,
            prompt: "MacFan 需要安装一个后台服务来调节风扇转速，此后不再需要输入密码。"
        )
        guard result.success else { return result }

        switch currentStatus() {
        case .installed:
            return (true, "Helper 已安装为系统服务")
        case .outdated:
            return (false, "Helper 已安装，但与当前 App 版本不一致")
        case .notInstalled, .checking:
            return (false, "Helper 已复制，但系统服务未成功启动")
        }
    }

    /// 卸载 Helper
    @MainActor
    static func uninstall() -> (success: Bool, message: String) {
        let script = """
        launchctl bootout system/\(serviceLabel) 2>/dev/null || true
        rm -f '\(helperInstallPath)' '\(plistInstallPath)'
        echo OK
        """
        let result = runPrivileged(script: script, prompt: "MacFan 需要移除风扇控制后台服务。")
        return result.success ? (true, "Helper 已卸载") : result
    }

    /// 以管理员权限运行 shell 脚本。脚本写入临时文件，避免拼接复杂的转义命令。
    @MainActor
    private static func runPrivileged(script: String, prompt: String) -> (success: Bool, message: String) {
        let tmpScript = NSTemporaryDirectory() + "macfan_\(UUID().uuidString).sh"
        do {
            try script.write(toFile: tmpScript, atomically: true, encoding: .utf8)
        } catch {
            return (false, "无法写入临时脚本: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(atPath: tmpScript) }

        let source = """
        do shell script "/bin/bash " & quoted form of \(appleScriptString(tmpScript)) \
        with prompt \(appleScriptString(prompt)) with administrator privileges
        """
        var errorDict: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&errorDict)

        if let error = errorDict {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 {
                return (false, "已取消")
            }
            return (false, error[NSAppleScript.errorMessage] as? String ?? "未知错误")
        }
        guard output?.stringValue?.contains("OK") == true else {
            return (false, "脚本未返回成功标记")
        }
        return (true, "OK")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 查找 app bundle 中的 helper 二进制
    private static func findHelperBinary() -> String? {
        guard let executablePath = Bundle.main.executablePath else { return nil }
        let path = ((executablePath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("MacFanHelper")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

/// 界面使用的 Helper 状态，检查在后台线程进行
@MainActor
final class HelperController: ObservableObject {
    @Published private(set) var status: HelperStatus = .checking
    @Published private(set) var isWorking = false

    var canControlFans: Bool { status == .installed }

    func refresh() {
        Task {
            let status = await Task.detached(priority: .utility) {
                HelperInstaller.currentStatus()
            }.value
            self.status = status
        }
    }

    func install(completion: @escaping (Bool, String) -> Void) {
        run({ HelperInstaller.install() }, completion: completion)
    }

    func uninstall(completion: @escaping (Bool, String) -> Void) {
        run({ HelperInstaller.uninstall() }, completion: completion)
    }

    private func run(
        _ operation: @escaping @MainActor () -> (success: Bool, message: String),
        completion: @escaping (Bool, String) -> Void
    ) {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            // 先让界面显示进度状态，再进入会阻塞主线程的授权流程
            try? await Task.sleep(for: .milliseconds(50))
            let result = operation()
            self.isWorking = false
            self.refresh()
            completion(result.success, result.message)
        }
    }
}
