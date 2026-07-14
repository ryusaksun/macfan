import Foundation

/// SMC 写操作实现（以 root 权限运行）。具体控制和回滚逻辑由 MacFanCore 共享引擎负责。
final class SMCWriter: NSObject, HelperProtocol {
    /// SMC 是全局硬件状态，所有 XPC 连接必须共享同一个串行控制引擎。
    private static let sharedEngine = FanControlEngine(smc: SMCKit())
    private let engine: FanControlEngine

    override init() {
        engine = Self.sharedEngine
        super.init()
    }

    func setFanSpeed(fanID: Int, rpm: Double, withReply reply: @escaping (Bool, String) -> Void) {
        send(engine.setFanSpeed(fanID: fanID, rpm: rpm), to: reply)
    }

    func setAllFans(percent: Double, withReply reply: @escaping (Bool, String) -> Void) {
        send(engine.setAllFans(percent: percent), to: reply)
    }

    func resetFan(fanID: Int, withReply reply: @escaping (Bool, String) -> Void) {
        send(engine.resetFan(fanID: fanID), to: reply)
    }

    func setAllFansMax(withReply reply: @escaping (Bool, String) -> Void) {
        send(engine.setAllFansMax(), to: reply)
    }

    func resetAllFans(withReply reply: @escaping (Bool, String) -> Void) {
        send(engine.resetAllFans(), to: reply)
    }

    func ping(withReply reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    private func send(_ result: FanControlResult, to callback: (Bool, String) -> Void) {
        callback(result.success, result.message)
    }
}
