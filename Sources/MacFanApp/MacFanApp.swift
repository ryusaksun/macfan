import SwiftUI

@main
struct MacFanApp: App {
    @StateObject private var monitor = FanMonitor(interval: 2.0)
    @StateObject private var profileManager = ProfileManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(monitor: monitor, profileManager: profileManager)
                .onAppear { monitor.profileManager = profileManager }
        } label: {
            Label {
                Text("MacFan")
            } icon: {
                Image(systemName: "fan.fill")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
