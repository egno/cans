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
                if headphones.isBatteryLow, let red = LowBatteryText.image("\(battery)%") {
                    Image(nsImage: red)
                } else {
                    Text("\(battery)%")
                }
            }
        case .searching, .unavailable:
            Image(systemName: "headphones.slash")
        }
    }
}

/// The menu bar draws its label as a template, which drops colour, so a low
/// battery is rendered to a non-template image in the menu bar font instead.
@MainActor
enum LowBatteryText {
    static func image(_ text: String) -> NSImage? {
        let font = NSFont.menuBarFont(ofSize: 0)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
            .foregroundColor: NSColor.systemRed,
        ])
        let size = attributed.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { rect in
            attributed.draw(in: rect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Battery low, \(text)"
        return image
    }
}
