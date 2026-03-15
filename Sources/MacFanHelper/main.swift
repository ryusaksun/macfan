import Foundation

/// MacFanHelper 入口
/// 作为 LaunchDaemon 以 root 权限运行，通过 XPC 接收主 App 的风扇控制请求
let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: "com.macfan.helper")
listener.delegate = delegate
listener.resume()

// 优雅关闭：收到 SIGTERM 时退出 RunLoop
let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
sigSource.setEventHandler {
    CFRunLoopStop(CFRunLoopGetMain())
}
sigSource.resume()

RunLoop.current.run()
