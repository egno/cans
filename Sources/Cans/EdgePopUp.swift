import AppKit
import SwiftUI

/// A compact pop-up picker whose menu stays visible next to another display.
///
/// On macOS 27 a menu's glass backdrop is a window of its own. When a small menu opens
/// at a screen's right edge and that backdrop reaches onto the display beside it, AppKit
/// moves the backdrop one screen width to the left, off every display. The menu is open
/// but can't be seen, and it looks as if it closed at once. The popover sits under its
/// menu bar item, at the right edge, so every picker on its right side was affected.
/// This opens such a menu a little to the left instead, so the backdrop stays on its own
/// screen. Elsewhere it's an ordinary pop-up button.
struct EdgePopUp<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    func makeNSView(context: Context) -> EdgePopUpButton {
        let button = EdgePopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .mini
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: EdgePopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(label)
        if button.itemTitles != titles {
            button.removeAllItems()
            // addItems(withTitles:) drops repeated titles; each option needs its own item.
            for title in titles {
                button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        if let index = options.firstIndex(of: selection) {
            button.selectItem(at: index)
        } else {
            button.select(nil)
        }
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(title)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: EdgePopUp
        init(parent: EdgePopUp) { self.parent = parent }

        @objc func picked(_ button: NSPopUpButton) {
            let index = button.indexOfSelectedItem
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index]
        }
    }
}

final class EdgePopUpButton: NSPopUpButton {
    /// How far the backdrop reaches past the menu on each side, with a little to spare.
    private static let backdropMargin: CGFloat = 80

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let menu, let window, let screen = window.screen else {
            return super.mouseDown(with: event)
        }
        let frame = window.convertToScreen(convert(bounds, to: nil))
        menu.update()
        let width = max(menu.size.width, frame.width)
        let overflow = frame.minX + width + Self.backdropMargin - screen.frame.maxX
        guard overflow > 0, Self.hasScreen(rightOf: screen) else {
            return super.mouseDown(with: event)
        }
        // Over the button like a pop-up's own menu, with the selected item on the title.
        menu.popUp(positioning: selectedItem, at: NSPoint(x: -overflow, y: isFlipped ? bounds.maxY - 2 : 2), in: self)
    }

    /// At a right edge with nothing beyond it the menu opens where AppKit puts it.
    private static func hasScreen(rightOf screen: NSScreen) -> Bool {
        NSScreen.screens.contains { $0 != screen && abs($0.frame.minX - screen.frame.maxX) < 1 }
    }
}
