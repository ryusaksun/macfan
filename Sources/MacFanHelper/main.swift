import Foundation

/// MacFanHelper 入口
/// 作为 LaunchDaemon 以 root 权限运行，通过 XPC 接收主 App 的风扇控制请求
let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
listener.resume()

// 收到 SIGTERM（launchctl bootout / 重新安装）时直接退出。
// RunLoop.run() 会在 CFRunLoopStop 后重新进入循环，停止 RunLoop 无法让进程退出。
let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
sigSource.setEventHandler {
    exit(EXIT_SUCCESS)
}
sigSource.resume()

RunLoop.current.run()
