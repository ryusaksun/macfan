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
    /// 每次新建连接递增，旧连接的失效回调不能清掉新连接
    private var connectionGeneration = 0
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
            connectionGeneration &+= 1
            let generation = connectionGeneration
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in
                    guard let self, self.connectionGeneration == generation else { return }
                    self.connection = nil
                }
            }
            // 中断（例如 Helper 重启）后连接仍可复用，下次发送消息时会自动重连
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
            let message = Self.describe(error)
            Task { @MainActor in
                once.finish(FanControlResult(success: false, message: message))
            }
        }) else {
            once.finish(FanControlResult(success: false, message: "无法连接到 Helper，请先安装 Helper"))
            return
        }

        let timeout = timeout
        once.timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            once.finish(FanControlResult(success: false, message: "Helper 操作超时"))
        }

        operation(helper) { success, message in
            Task { @MainActor in
                once.finish(FanControlResult(success: success, message: message))
            }
        }
    }

    private nonisolated static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSXPCConnectionInvalid || nsError.code == NSXPCConnectionInterrupted {
            return "无法连接到 Helper，请确认 Helper 已安装并在运行"
        }
        return "XPC: \(error.localizedDescription)"
    }
}

@MainActor
private final class CompletionOnce {
    private var completion: FanControlCompletion?
    var timeoutTask: Task<Void, Never>?

    init(completion: @escaping FanControlCompletion) {
        self.completion = completion
    }

    func finish(_ result: FanControlResult) {
        guard let completion else { return }
        self.completion = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        completion(result)
    }
}
