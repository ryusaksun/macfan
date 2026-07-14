import Foundation

public typealias FanControlCompletion = @MainActor @Sendable (FanControlResult) -> Void

@MainActor
public protocol FanControlClient: AnyObject {
    func setFanSpeed(fanID: Int, rpm: Double, completion: @escaping FanControlCompletion)
    func setAllFans(percent: Double, completion: @escaping FanControlCompletion)
    func setAllFansMax(completion: @escaping FanControlCompletion)
    func resetFan(fanID: Int, completion: @escaping FanControlCompletion)
    func resetAllFans(completion: @escaping FanControlCompletion)
    func invalidate()
}

@MainActor
public final class XPCFanControlClient: FanControlClient {
    private var connection: NSXPCConnection?
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    public func setFanSpeed(fanID: Int, rpm: Double, completion: @escaping FanControlCompletion) {
        perform(completion: completion) { helper, reply in
            helper.setFanSpeed(fanID: fanID, rpm: rpm, withReply: reply)
        }
    }

    public func setAllFans(percent: Double, completion: @escaping FanControlCompletion) {
        perform(completion: completion) { helper, reply in
            helper.setAllFans(percent: percent, withReply: reply)
        }
    }

    public func setAllFansMax(completion: @escaping FanControlCompletion) {
        perform(completion: completion) { helper, reply in
            helper.setAllFansMax(withReply: reply)
        }
    }

    public func resetFan(fanID: Int, completion: @escaping FanControlCompletion) {
        perform(completion: completion) { helper, reply in
            helper.resetFan(fanID: fanID, withReply: reply)
        }
    }

    public func resetAllFans(completion: @escaping FanControlCompletion) {
        perform(completion: completion) { helper, reply in
            helper.resetAllFans(withReply: reply)
        }
    }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func getHelper(errorHandler: @escaping @Sendable (Error) -> Void) -> HelperProtocol? {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in
                    self?.connection = nil
                }
            }
            connection.interruptionHandler = { [weak self] in
                Task { @MainActor in
                    self?.connection = nil
                }
            }
            connection.resume()
            self.connection = connection
        }

        return connection?.remoteObjectProxyWithErrorHandler(errorHandler) as? HelperProtocol
    }

    private func perform(
        completion: @escaping FanControlCompletion,
        operation: (HelperProtocol, @escaping (Bool, String) -> Void) -> Void
    ) {
        let once = CompletionOnce(completion: completion)
        guard let helper = getHelper(errorHandler: { error in
            Task { @MainActor in
                once.finish(FanControlResult(success: false, message: "XPC: \(error.localizedDescription)"))
            }
        }) else {
            once.finish(FanControlResult(success: false, message: "无法连接到 Helper，请先安装 Helper"))
            return
        }

        operation(helper) { success, message in
            Task { @MainActor in
                once.finish(FanControlResult(success: success, message: message))
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            once.finish(FanControlResult(success: false, message: "Helper 操作超时"))
        }
    }
}

@MainActor
private final class CompletionOnce {
    private var completion: FanControlCompletion?

    init(completion: @escaping FanControlCompletion) {
        self.completion = completion
    }

    func finish(_ result: FanControlResult) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
    }
}
