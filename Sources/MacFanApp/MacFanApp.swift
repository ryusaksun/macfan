import SwiftUI

@main
struct MacFanApp: App {
    @StateObject private var monitor: FanMonitor
    @StateObject private var profileManager: ProfileManager
    @AppStorage("showTempInMenuBar") private var showTempInMenuBar: Bool = false
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let profileManager = ProfileManager()
        let monitor = FanMonitor(interval: Self.initialRefreshInterval)
        monitor.profileManager = profileManager

        _monitor = StateObject(wrappedValue: monitor)
        _profileManager = StateObject(wrappedValue: profileManager)

        AppDelegate.sharedMonitor = monitor
        DispatchQueue.main.async {
            monitor.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(monitor: monitor, profileManager: profileManager)
        } label: {
            Label {
                Text(menuBarTitle)
            } icon: {
                Image(systemName: "fan.fill")
            }
        }
        .menuBarExtraStyle(.window)
    }

    private static var initialRefreshInterval: TimeInterval {
        let storedInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        return storedInterval > 0 ? storedInterval : 2.0
    }

    private var menuBarTitle: String {
        guard showTempInMenuBar, monitor.maxTemp > 0 else { return "MacFan" }
        return "\(Int(monitor.maxTemp))°C"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedMonitor: FanMonitor?

    private var terminationPending = false
    private var terminationTimeout: Task<Void, Never>?

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

        terminationTimeout = Task { @MainActor [weak self, weak sender] in
            try? await Task.sleep(for: .seconds(60))
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
