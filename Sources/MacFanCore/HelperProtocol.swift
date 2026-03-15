import Foundation

/// XPC 协议：主 App 与特权 Helper 之间的通信接口
/// Helper 以 root 运行，负责 SMC 写操作
@objc public protocol HelperProtocol {
    /// 设置指定风扇的目标转速
    func setFanSpeed(fanID: Int, rpm: Double, withReply reply: @escaping (Bool, String) -> Void)

    /// 所有风扇全速
    func setAllFansMax(withReply reply: @escaping (Bool, String) -> Void)

    /// 恢复所有风扇自动控制
    func resetAllFans(withReply reply: @escaping (Bool, String) -> Void)

    /// 检查 Helper 是否存活
    func ping(withReply reply: @escaping (Bool) -> Void)
}

/// Helper 的 Mach service 名称
public let helperMachServiceName = "com.macfan.helper"
