import Foundation
import Security

/// XPC 连接委托：验证并接受来自主 App 的连接
final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    private let clientRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"2FJFJ2WAF8\" and identifier \"com.macfan.MacFan\""

    /// 验证连接方必须是同一团队签名的 MacFan 主应用。
    private func isValidClient(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier

        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let secCode = code else {
            NSLog("MacFanHelper: 无法获取 PID \(pid) 的 SecCode")
            return false
        }

        // 同时绑定 Apple 签名链、Team ID 和主应用 identifier。
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(clientRequirement as CFString, [], &requirement) == errSecSuccess,
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
        newConnection.setCodeSigningRequirement(clientRequirement)

        newConnection.invalidationHandler = {
            // 连接断开时的清理
        }

        newConnection.resume()
        return true
    }
}
