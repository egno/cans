import AppKit
import SwiftUI

@main
struct CansApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { delegate.manager.isInMenuBar }, set: { _ in })) {
            MenuView(manager: delegate.manager)
        } label: {
            MenuBarLabel(manager: delegate.manager)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = HeadphonesManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, even when launched outside the .app bundle (swift run).
        NSApp.setActivationPolicy(.accessory)
    }

    /// Opening Cans again while it's hidden shows it until the headphones connect.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        manager.reveal()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.shutdown()
    }
}

/// One symbol for the connection state, plus the shown pair's battery level unless turned
/// off in settings. The level turns red when any connected pair is low.
struct MenuBarLabel: View {
    let manager: HeadphonesManager
    @AppStorage(Prefs.showBatteryInMenuBar) private var showBattery = true

    var body: some View {
        switch manager.status {
        case .connected:
            Image(systemName: "headphones")
            if showBattery, let session = manager.selected, let battery = session.battery {
                let low = manager.lowBatterySessions.compactMap { s in s.battery.map { (s.displayName, $0) } }
                if !low.isEmpty, let red = LowBatteryText.image(
                    "\(battery)%",
                    description: LowBatteryText.description(shown: session.displayName, percent: battery, low: low)) {
                    Image(nsImage: red)
                } else {
                    // Fixed-width digits, so the menu bar item doesn't shift as the level changes.
                    Text("\(battery)%").monospacedDigit()
                }
            }
        case .searching:
            // Dimmed while a look is under way, so it's distinguishable from "not connected".
            if let dimmed = DimmedSymbol.image("headphones.slash", description: "Looking for headphones") {
                Image(nsImage: dimmed)
            } else {
                Image(systemName: "headphones.slash")
            }
        case .unavailable:
            Image(systemName: "headphones.slash")
        }
    }
}

/// A menu bar symbol at half strength. It stays a template, whose alpha the menu bar
/// keeps, so it still follows light, dark and tinted menu bars.
@MainActor
enum DimmedSymbol {
    static func image(_ name: String, description: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config) else { return nil }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.45)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}

/// The menu bar draws its label as a template, which drops colour, so a low
/// battery is rendered to a non-template image in the menu bar font instead.
@MainActor
enum LowBatteryText {
    static func image(_ text: String, description: String) -> NSImage? {
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
        image.accessibilityDescription = description
        return image
    }

    /// Names the low pair, which may not be the one whose level is shown:
    /// "Atom 80%; High Note battery low, 12%".
    static func description(shown: String, percent: Int, low: [(name: String, percent: Int)]) -> String {
        let lows = low.map { "\($0.name) battery low, \($0.percent)%" }
        if low.contains(where: { $0.name == shown }) { return lows.joined(separator: "; ") }
        return (["\(shown) \(percent)%"] + lows).joined(separator: "; ")
    }
}
