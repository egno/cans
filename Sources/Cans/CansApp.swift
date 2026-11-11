import AppKit
import SwiftUI

@main
struct CansApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { delegate.headphones.isInMenuBar }, set: { _ in })) {
            MenuView(headphones: delegate.headphones)
        } label: {
            MenuBarLabel(headphones: delegate.headphones)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let headphones = Headphones()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, even when launched outside the .app bundle (swift run).
        NSApp.setActivationPolicy(.accessory)
    }

    /// Opening Cans again while it's hidden shows it until the headphones connect.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        headphones.reveal()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        headphones.shutdown()
    }
}

/// One symbol for the connection state, plus the battery level unless turned off in settings.
struct MenuBarLabel: View {
    let headphones: Headphones
    @AppStorage(Prefs.showBatteryInMenuBar) private var showBattery = true

    var body: some View {
        switch headphones.status {
        case .connected:
            Image(systemName: "headphones")
            if showBattery, let battery = headphones.battery {
                Text("\(battery)%")
            }
        case .searching, .unavailable:
            Image(systemName: "headphones.slash")
        }
    }
}
