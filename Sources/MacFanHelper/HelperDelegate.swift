import Foundation
import Security

/// XPC 连接委托：验证并接受来自主 App 的连接
final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    /// 验证连接方的代码签名是否来自同一团队
    private func isValidClient(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        let teamID = "2FJFJ2WAF8"

        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let secCode = code else {
            NSLog("MacFanHelper: 无法获取 PID \(pid) 的 SecCode")
            return false
        }

        // 使用 SecRequirement 验证签名和 team ID（比手动解析 signingInfo 更稳健）
        let reqString = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"" as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqString, [], &requirement) == errSecSuccess,
              let req = requirement else {
            NSLog("MacFanHelper: 无法创建签名校验规则")
            return false
        }

        let status = SecCodeCheckValidity(secCode, [], req)
        if status != errSecSuccess {
            NSLog("MacFanHelper: PID \(pid) 签名校验失败: \(status)")
            return false
        }

        return true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // 验证调用方身份
        guard isValidClient(newConnection) else {
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = SMCWriter()

        newConnection.invalidationHandler = {
            // 连接断开时的清理
        }

        newConnection.resume()
        return true
    }
}
