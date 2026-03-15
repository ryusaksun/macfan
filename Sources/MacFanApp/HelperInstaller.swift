import Foundation

/// 一次性安装特权 Helper 为系统 LaunchDaemon
/// 安装后 Helper 以 root 运行，App 通过 XPC 通信，不再需要密码
enum HelperInstaller {
    static let helperInstallPath = "/Library/PrivilegedHelperTools/com.macfan.helper"
    static let plistInstallPath = "/Library/LaunchDaemons/com.macfan.helper.plist"
    static let serviceLabel = "com.macfan.helper"

    /// 检查 Helper 是否已安装
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: helperInstallPath)
    }

    /// 检查 daemon 是否正在运行
    static var isRunning: Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "system/\(serviceLabel)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// 安装 Helper（弹出一次密码框）
    static func install() -> (success: Bool, message: String) {
        // 找到 app bundle 中的 helper 二进制
        guard let helperSrc = findHelperBinary() else {
            return (false, "找不到 MacFanHelper 二进制")
        }

        // 生成安装用的 launchd plist（使用绝对路径）
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

        // 构建安装脚本
        let script = """
        mkdir -p /Library/PrivilegedHelperTools && \
        cp '\(helperSrc)' '\(helperInstallPath)' && \
        chmod 755 '\(helperInstallPath)' && \
        cat > '\(plistInstallPath)' << 'PLISTEOF'
        \(plistContent)
        PLISTEOF
        launchctl bootout system/\(serviceLabel) 2>/dev/null; \
        launchctl bootstrap system '\(plistInstallPath)' && \
        echo 'OK'
        """

        let appleScript = NSAppleScript(source:
            "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        )

        // 更简单的方式：直接写临时脚本文件
        let tmpScript = NSTemporaryDirectory() + "macfan_install_\(UUID().uuidString).sh"
        do {
            try script.write(toFile: tmpScript, atomically: true, encoding: .utf8)
        } catch {
            return (false, "无法写入临时脚本: \(error.localizedDescription)")
        }

        let installAppleScript = NSAppleScript(source:
            "do shell script \"bash '\(tmpScript)'\" with administrator privileges"
        )

        var errorDict: NSDictionary?
        let result = installAppleScript?.executeAndReturnError(&errorDict)

        // 清理临时脚本
        try? FileManager.default.removeItem(atPath: tmpScript)

        if let error = errorDict {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            if msg.contains("User canceled") {
                return (false, "已取消安装")
            }
            return (false, msg)
        }

        let output = result?.stringValue ?? ""
        if output.contains("OK") {
            return (true, "Helper 已安装为系统服务")
        }
        return (true, "安装完成")
    }

    /// 卸载 Helper
    static func uninstall() -> (success: Bool, message: String) {
        let script = """
        launchctl bootout system/\(serviceLabel) 2>/dev/null; \
        rm -f '\(helperInstallPath)' '\(plistInstallPath)' && \
        echo 'OK'
        """

        let tmpScript = NSTemporaryDirectory() + "macfan_uninstall_\(UUID().uuidString).sh"
        do {
            try script.write(toFile: tmpScript, atomically: true, encoding: .utf8)
        } catch {
            return (false, "无法写入临时脚本: \(error.localizedDescription)")
        }

        let appleScript = NSAppleScript(source:
            "do shell script \"bash '\(tmpScript)'\" with administrator privileges"
        )

        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        try? FileManager.default.removeItem(atPath: tmpScript)

        if let error = errorDict {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            return (false, msg)
        }
        return (true, "Helper 已卸载")
    }

    /// 查找 app bundle 中的 helper 二进制
    private static func findHelperBinary() -> String? {
        if let bundlePath = Bundle.main.executablePath {
            let dir = (bundlePath as NSString).deletingLastPathComponent
            let path = (dir as NSString).appendingPathComponent("MacFanHelper")
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
}
