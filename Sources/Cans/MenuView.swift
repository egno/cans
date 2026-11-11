import BMAP
import ServiceManagement
import SwiftUI

/// Settings keys shared by the popover and the menu bar label.
extension Color {
    /// The icon's electric blue, used as the popover's tint.
    static let cans = Color(red: 0x1E / 255, green: 0x9B / 255, blue: 0xFF / 255)
}

enum Prefs {
    static let showBatteryInMenuBar = "showBatteryInMenuBar"
    static let showEqualizer = "showEqualizer"
    static let showDevices = "showDevices"
}

struct MenuView: View {
    @Bindable var headphones: Headphones
    @AppStorage(Prefs.showEqualizer) private var showEqualizer = false
    @AppStorage(Prefs.showDevices) private var showDevices = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DeviceCard(headphones: headphones) { SettingsMenu(headphones: headphones) }
                // The text column's spacer would otherwise take whatever height the window offers.
                .fixedSize(horizontal: false, vertical: true)
            if let error = headphones.lastError {
                Banner(text: error) { headphones.dismissError() }
            }
            if headphones.status == .connected {
                Divider()
                modes
                if !headphones.devices.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        SectionToggle(title: "Devices", detail: devicesSummary, isExpanded: $showDevices)
                        if showDevices {
                            DeviceList(headphones: headphones)
                        }
                    }
                }
                if !headphones.eq.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        SectionToggle(title: "Equalizer", detail: eqSummary, isExpanded: $showEqualizer)
                        if showEqualizer {
                            EQPanel(headphones: headphones)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .tint(.cans)
        .animation(.snappy(duration: 0.25), value: headphones.currentMode)
        .animation(.snappy(duration: 0.25), value: headphones.status)
        .animation(.snappy(duration: 0.25), value: headphones.devices)
        // The list changes when other devices connect, so catch up whenever the popover opens.
        .onAppear { if headphones.status == .connected { headphones.refreshDevices() } }
    }

    private var devicesSummary: String {
        "\(headphones.devices.filter(\.isConnected).count) connected"
    }

    private var modes: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Modes")
            if headphones.modes.isEmpty {
                ProgressView().controlSize(.small).padding(.horizontal, 6)
            }
            ForEach(headphones.modes) { mode in
                ModeRow(mode: mode, isSelected: headphones.currentMode == mode.index) {
                    headphones.selectMode(mode.index)
                }
            }
        }
    }

    /// "Flat", or the bands that aren't at zero: "Bass +8 · Treble −2".
    private var eqSummary: String {
        let changed = headphones.eq.filter { $0.value != 0 }.sorted { $0.kind.rawValue < $1.kind.rawValue }
        guard !changed.isEmpty else { return "Flat" }
        return changed.map { "\($0.kind.label) \(signed($0.value))" }.joined(separator: " · ")
    }
}

private func signed(_ v: Int) -> String {
    v > 0 ? "+\(v)" : v < 0 ? "−\(-v)" : "0"
}

// MARK: - Device card

/// Name, mode and battery of the headphones: a compact version of progradio's now-playing card.
private struct DeviceCard<Accessory: View>: View {
    let headphones: Headphones
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(modelLabel, systemImage: headphones.status == .connected ? "headphones" : "headphones.slash")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(headphones.status == .connected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if headphones.status == .connected, let battery = headphones.battery {
                    BatteryLabel(percent: battery, isLow: headphones.isBatteryLow)
                }
                accessory()
            }
            Text(headphones.name ?? "Bose Headphones")
                .font(.headline)
                .lineLimit(1)
            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
    }

    private var modelLabel: String {
        let model = headphones.model.map { $0.replacingOccurrences(of: "Bose ", with: "") } ?? "Headphones"
        return model.uppercased()
    }

    private var statusLine: String {
        switch headphones.status {
        case .searching: "Connecting…"
        case .unavailable: "Not connected"
        case .connected: headphones.currentModeSlot.map { "\($0.name) mode" } ?? "Connected"
        }
    }
}

/// "60%" with a battery symbol; red when low.
private struct BatteryLabel: View {
    let percent: Int
    let isLow: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text("\(percent)%").monospacedDigit()
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(isLow ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .help("Battery \(percent)%")
    }

    private var symbol: String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

// MARK: - Modes

private struct ModeRow: View {
    let mode: ModeSlot
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.cans.opacity(hovering ? 0.18 : 0.12)) }
        return hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mode.symbol)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.name)
                        .fontWeight(isSelected ? .semibold : .regular)
                    Text(isSelected ? "Active" : mode.summary)
                        .font(.caption)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(background))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isSelected ? "" : "Switch to \(mode.name)")
    }
}

private extension ModeSlot {
    var symbol: String {
        switch name.lowercased() {
        case "quiet": "waveform.slash"
        case "aware": "ear"
        case "immersion": "person.wave.2"
        default: "slider.horizontal.3"
        }
    }

    var summary: String {
        switch name.lowercased() {
        case "quiet": "Full noise cancelling"
        case "aware": "Hear your surroundings"
        case "immersion": "Spatial audio"
        default: "Custom mode"
        }
    }
}

// MARK: - Devices

/// Paired devices; clicking one connects it, connected ones other than this Mac can be disconnected.
private struct DeviceList: View {
    let headphones: Headphones

    var body: some View {
        ForEach(headphones.devices, id: \.address) { device in
            DeviceRow(device: device,
                      isThisMac: headphones.isThisMac(device),
                      isPending: headphones.pendingDevices.contains(device.address),
                      replaces: replaced(byConnecting: device),
                      connect: { headphones.connect(device) },
                      disconnect: { headphones.disconnect(device) })
        }
    }

    /// With two devices connected, the headphones drop the one that isn't playing.
    private func replaced(byConnecting device: DeviceInfo) -> DeviceInfo? {
        let connected = headphones.devices.filter(\.isConnected)
        guard !device.isConnected, connected.count >= 2 else { return nil }
        return connected.first { !$0.isActive }
    }
}

private struct DeviceRow: View {
    let device: DeviceInfo
    let isThisMac: Bool
    let isPending: Bool
    let replaces: DeviceInfo?
    let connect: () -> Void
    let disconnect: () -> Void
    @State private var hovering = false

    private var canConnect: Bool { !device.isConnected && !isPending }
    private var canDisconnect: Bool { device.isConnected && !isThisMac && !isPending }

    var body: some View {
        Button { if canConnect { connect() } } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(device.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(isThisMac ? "This Mac" : device.name)
                        .fontWeight(device.isActive ? .semibold : .regular)
                        .lineLimit(1)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(device.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer()
                if isPending {
                    ProgressView().controlSize(.small)
                } else if canDisconnect, hovering {
                    Button(action: disconnect) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Disconnect \(device.name)")
                } else if device.isConnected {
                    Circle().fill(device.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 6, height: 6)
                        .padding(.trailing, 4)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering && canConnect ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        }
        .buttonStyle(.plain)
        .disabled(!canConnect && !canDisconnect)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var status: String {
        switch (isPending, device.isConnected) {
        case (true, false): "Connecting…"
        case (true, true): "Disconnecting…"
        case (false, true): device.isActive ? "Active" : "Connected"
        case (false, false): "Not connected"
        }
    }

    private var help: String {
        guard canConnect else { return "" }
        if let replaces { return "Connect \(device.name); disconnects \(replaces.name)" }
        return "Connect \(device.name)"
    }

    private var symbol: String {
        let name = device.name.lowercased()
        if isThisMac || name.contains("macbook") || name.hasPrefix("mac-") { return "laptopcomputer" }
        if name.contains("ipad") { return "ipad" }
        if name.contains("imac") || name.contains("mac mini") || name.contains("mac studio") { return "desktopcomputer" }
        if name.contains("watch") { return "applewatch" }
        if name.contains("tv") { return "tv" }
        return name.contains("iphone") ? "iphone" : "smartphone"
    }
}

// MARK: - Equalizer

/// Treble on top, like a mixing console.
private struct EQPanel: View {
    let headphones: Headphones

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(headphones.eq.sorted { $0.kind.rawValue > $1.kind.rawValue }) { band in
                EQSlider(band: band) { headphones.setEQ(band.kind, value: $0) }
            }
            if headphones.eq.contains(where: { $0.value != 0 }) {
                HStack {
                    Spacer()
                    Button("Reset to flat") {
                        for band in headphones.eq where band.value != 0 {
                            headphones.setEQ(band.kind, value: 0)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .padding(.horizontal, 6)
    }
}

private struct EQSlider: View {
    let band: EQBand
    let commit: (Int) -> Void
    @State private var value: Double = 0
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            Text(band.kind.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Slider(value: $value,
                   in: Double(band.range.lowerBound)...Double(band.range.upperBound),
                   step: 1) { isEditing in
                editing = isEditing
                if !isEditing, Int(value) != band.value { commit(Int(value)) }
            }
            .controlSize(.small)
            Text(signed(Int(value)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
        .onAppear { value = Double(band.value) }
        .onChange(of: band.value) { _, new in if !editing { value = Double(new) } }
    }
}

// MARK: - Settings

/// Set-once options and links, kept out of the way in a gear menu.
private struct SettingsMenu: View {
    @Bindable var headphones: Headphones
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(Prefs.showBatteryInMenuBar) private var showBatteryInMenuBar = true

    /// "Cans 0.1.0 (6)" from the bundle; unbundled builds (swift run) have no Info.plist.
    static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "Cans development build" }
        let build = (info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        return "Cans \(version)\(build)"
    }()

    var body: some View {
        Menu {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { enabled in
                    if enabled {
                        try? SMAppService.mainApp.register()
                    } else {
                        try? SMAppService.mainApp.unregister()
                    }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
            Toggle("Show battery in menu bar", isOn: $showBatteryInMenuBar)
            Toggle("Hide when disconnected", isOn: $headphones.hideWhenDisconnected)
            Toggle("Announce mode changes", isOn: $headphones.announceModeChanges)
            Toggle("Low battery alerts", isOn: $headphones.lowBatteryAlerts)
            if let autoPause = headphones.autoPause {
                Toggle("Pause when taken off", isOn: Binding(
                    get: { autoPause }, set: { headphones.setAutoPause($0) }))
            }
            if let autoAnswer = headphones.autoAnswer {
                Toggle("Answer calls when put on", isOn: Binding(
                    get: { autoAnswer }, set: { headphones.setAutoAnswer($0) }))
            }
            if let multipoint = headphones.multipoint {
                Toggle("Connect to two devices", isOn: Binding(
                    get: { multipoint }, set: { headphones.setMultipoint($0) }))
            }
            Divider()
            if headphones.status == .connected {
                Button("Refresh") { headphones.refresh() }
            }
            Divider()
            Text(Self.appVersion)
            if let firmware = headphones.firmware {
                Text("Headphones firmware \(firmware)")
            }
            Button("Send Feedback…") { NSWorkspace.shared.open(URL(string: "https://github.com/egno/cans/issues")!) }
            Divider()
            Button("Quit Cans") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Settings")
    }
}

// MARK: - Shared pieces (same as progradio)

/// A full-width strip for problems.
private struct Banner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.red.opacity(0.1)))
    }
}

/// A section's caption title.
private struct SectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(title).fontWeight(.medium)
            if let detail {
                Text(detail).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}

/// A section header that shows or hides the section below it, with the chevron trailing so titles line up.
private struct SectionToggle: View {
    let title: String
    var detail: String?
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack {
                SectionHeader(title: title, detail: detail)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.trailing, 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
    }
}
