import Foundation
import ServiceManagement

/// 管理与特权 Helper 的 XPC 连接和 Helper 的安装/卸载
@MainActor
final class HelperManager: ObservableObject {
    @Published var isHelperInstalled = false
    @Published var isConnected = false
    @Published var lastError: String?
    @Published var lastMessage: String?

    private var connection: NSXPCConnection?

    static let shared = HelperManager()
    private init() {}

    // MARK: - Helper 安装

    func installHelper() {
        let service = SMAppService.daemon(plistName: "com.macfan.helper.plist")
        do {
            try service.register()
            isHelperInstalled = true
            lastError = nil
            lastMessage = "Helper 已安装"
        } catch {
            isHelperInstalled = false
            lastError = "安装 Helper 失败: \(error.localizedDescription)"
        }
    }

    func uninstallHelper() {
        let service = SMAppService.daemon(plistName: "com.macfan.helper.plist")
        do {
            try service.unregister()
            isHelperInstalled = false
            connection?.invalidate()
            connection = nil
            isConnected = false
            lastMessage = "Helper 已卸载"
        } catch {
            lastError = "卸载 Helper 失败: \(error.localizedDescription)"
        }
    }

    func checkHelperStatus() {
        let service = SMAppService.daemon(plistName: "com.macfan.helper.plist")
        isHelperInstalled = (service.status == .enabled)
    }

    // MARK: - XPC 连接

    private func getConnection() -> NSXPCConnection {
        if let conn = connection {
            return conn
        }

        let conn = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)

        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.isConnected = false
            }
        }

        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.isConnected = false
            }
        }

        conn.resume()
        connection = conn
        isConnected = true
        return conn
    }

    private func getHelper() -> HelperProtocol? {
        let conn = getConnection()
        return conn.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.lastError = "XPC 错误: \(error.localizedDescription)"
                self?.isConnected = false
            }
        } as? HelperProtocol
    }

    // MARK: - 风扇控制

    func setFanSpeed(fanID: Int, rpm: Double) {
        guard let helper = getHelper() else {
            lastError = "无法连接到 Helper"
            return
        }
        lastMessage = nil
        lastError = nil

        helper.setFanSpeed(fanID: fanID, rpm: rpm) { [weak self] success, message in
            Task { @MainActor in
                if success {
                    self?.lastMessage = message
                    self?.lastError = nil
                } else {
                    self?.lastError = message
                }
            }
        }
    }

    func setAllFansMax() {
        guard let helper = getHelper() else {
            lastError = "无法连接到 Helper"
            return
        }
        lastMessage = nil
        lastError = nil

        helper.setAllFansMax { [weak self] success, message in
            Task { @MainActor in
                if success {
                    self?.lastMessage = message
                    self?.lastError = nil
                } else {
                    self?.lastError = message
                }
            }
        }
    }

    func resetAllFans() {
        guard let helper = getHelper() else {
            lastError = "无法连接到 Helper"
            return
        }
        lastMessage = nil
        lastError = nil

        helper.resetAllFans { [weak self] success, message in
            Task { @MainActor in
                if success {
                    self?.lastMessage = message
                    self?.lastError = nil
                } else {
                    self?.lastError = message
                }
            }
        }
    }

    func pingHelper() {
        guard let helper = getHelper() else {
            isConnected = false
            return
        }

        helper.ping { [weak self] alive in
            Task { @MainActor in
                self?.isConnected = alive
            }
        }
    }
}
