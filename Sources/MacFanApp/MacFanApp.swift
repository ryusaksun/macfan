import SwiftUI

@main
struct MacFanApp: App {
    @StateObject private var monitor: FanMonitor
    @StateObject private var profileManager: ProfileManager
    @StateObject private var helper = HelperController()
    @AppStorage("showTempInMenuBar") private var showTempInMenuBar: Bool = false
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let editor: ProfileEditorController

    init() {
        let profileManager = ProfileManager()
        let monitor = FanMonitor(interval: Self.initialRefreshInterval)
        monitor.profileManager = profileManager

        _monitor = StateObject(wrappedValue: monitor)
        _profileManager = StateObject(wrappedValue: profileManager)
        editor = ProfileEditorController(profileManager: profileManager, monitor: monitor)

        AppDelegate.sharedMonitor = monitor
        DispatchQueue.main.async {
            monitor.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(monitor: monitor, profileManager: profileManager, helper: helper, editor: editor)
        } label: {
            if let temperature = menuBarTemperature {
                Image(nsImage: MenuBarIcon.image(text: temperature))
                    .accessibilityLabel("MacFan \(temperature)")
            } else {
                Image(systemName: "fan.fill")
                    .accessibilityLabel("MacFan")
            }
        }
        .menuBarExtraStyle(.window)
    }

    private static var initialRefreshInterval: TimeInterval {
        let storedInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        return storedInterval > 0 ? storedInterval : 2.0
    }

    private var menuBarTemperature: String? {
        guard showTempInMenuBar, monitor.maxTemp > 0 else { return nil }
        return "\(Int(monitor.maxTemp.rounded()))°"
    }
}

/// 菜单栏标签：MenuBarExtra 的 label 中 Label/HStack 不保证同时显示图标和文字，
/// 因此渲染成模板图片，深浅色菜单栏都能正确着色。
@MainActor
enum MenuBarIcon {
    private static var cache: (text: String, image: NSImage)?

    static func image(text: String) -> NSImage {
        if let cache, cache.text == text { return cache.image }

        let content = HStack(spacing: 3) {
            Image(systemName: "fan.fill")
                .font(.system(size: 13, weight: .medium))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(.black)

        let renderer = ImageRenderer(content: content)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else {
            return NSImage(systemSymbolName: "fan.fill", accessibilityDescription: "MacFan") ?? NSImage()
        }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        )
        image.isTemplate = true
        cache = (text, image)
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedMonitor: FanMonitor?

    private var terminationPending = false
    private var terminationTimeout: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppDelegate.sharedMonitor?.prepareForSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppDelegate.sharedMonitor?.resumeAfterWake() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        guard UserDefaults.standard.object(forKey: "autoRestoreOnQuit") as? Bool ?? true,
              let monitor = Self.sharedMonitor else {
            monitorAndStop()
            return .terminateNow
        }

        terminationPending = true
        monitor.resetAllFans { [weak self, weak sender] _ in
            guard let self, let sender else { return }
            finishTermination(application: sender)
        }

        // Helper 无响应时不要让退出卡住太久
        terminationTimeout = Task { @MainActor [weak self, weak sender] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, let sender else { return }
            finishTermination(application: sender)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorAndStop()
    }

    private func finishTermination(application: NSApplication) {
        guard terminationPending else { return }
        terminationPending = false
        terminationTimeout?.cancel()
        terminationTimeout = nil
        monitorAndStop()
        application.reply(toApplicationShouldTerminate: true)
    }

    private func monitorAndStop() {
        Self.sharedMonitor?.stop()
    }
}
