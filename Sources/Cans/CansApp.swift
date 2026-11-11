import AppKit
import SwiftUI

@main
struct CansApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
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

    func applicationWillTerminate(_ notification: Notification) {
        headphones.shutdown()
    }
}

struct MenuBarLabel: View {
    let headphones: Headphones

    var body: some View {
        if headphones.status == .connected, let battery = headphones.battery {
            Image(systemName: "headphones")
            Text("\(battery)%")
        } else {
            Image(systemName: "headphones").opacity(0.5)
        }
    }
}
