import Foundation
import UserNotifications

/// Posts a notification when the battery drops to 20% and again at 10%.
///
/// Each threshold fires once per discharge; it re-arms after the level climbs
/// back above it (the headphones were charged), so a reading that wobbles
/// around a threshold doesn't notify twice.
@MainActor
final class BatteryAlerts {
    static let thresholds = [20, 10]
    private static let rearmMargin = 5

    private var fired = Set<Int>()

    /// `UNUserNotificationCenter` traps outside an app bundle (e.g. `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func update(battery: Int, deviceName: String?) {
        for t in Self.thresholds where battery > t + Self.rearmMargin {
            fired.remove(t)
        }
        // Only the lowest crossed threshold, so connecting at 8% doesn't post twice.
        guard let threshold = Self.thresholds.filter({ battery <= $0 }).min(),
              !fired.contains(threshold) else { return }
        Self.thresholds.filter { $0 >= threshold }.forEach { fired.insert($0) }
        post(battery: battery, deviceName: deviceName)
    }

    private func post(battery: Int, deviceName: String?) {
        let content = UNMutableNotificationContent()
        content.title = "\(deviceName ?? "Headphones") battery low"
        content.body = "\(battery)% remaining"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "low-battery", content: content, trigger: nil)
        center?.add(request)
    }
}
