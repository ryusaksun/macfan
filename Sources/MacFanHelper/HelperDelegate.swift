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
            return false
        }

        // 验证签名有效
        guard SecCodeCheckValidity(secCode, [], nil) == errSecSuccess else {
            return false
        }

        // 获取 StaticCode 用于提取签名信息
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(secCode, [], &staticCode) == errSecSuccess,
              let secStaticCode = staticCode else {
            return false
        }

        // 提取签名信息，检查团队 ID
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(secStaticCode, [], &info) == errSecSuccess,
              let signingInfo = info as? [String: Any],
              let teamId = signingInfo["teamid"] as? String,
              teamId == teamID else {
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
