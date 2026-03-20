import SwiftUI

@main
struct MacFanApp: App {
    @StateObject private var monitor: FanMonitor
    @StateObject private var profileManager: ProfileManager
    @AppStorage("showTempInMenuBar") private var showTempInMenuBar: Bool = false
    private let terminationObserver: NSObjectProtocol

    init() {
        let profileManager = ProfileManager()
        let monitor = FanMonitor(interval: Self.initialRefreshInterval)
        monitor.profileManager = profileManager

        _monitor = StateObject(wrappedValue: monitor)
        _profileManager = StateObject(wrappedValue: profileManager)

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            monitor.stop()
        }

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
