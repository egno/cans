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
}

struct MenuView: View {
    @Bindable var headphones: Headphones
    @AppStorage(Prefs.showEqualizer) private var showEqualizer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DeviceCard(headphones: headphones) { SettingsMenu(headphones: headphones) }
                // The text column's spacer would otherwise take whatever height the window offers.
                .fixedSize(horizontal: false, vertical: true)
            if let error = headphones.lastError {
                Banner(text: error)
            }
            if headphones.status == .connected {
                Divider()
                modes
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

/// Name, mode and battery of the headphones, like progradio's now-playing card.
private struct DeviceCard<Accessory: View>: View {
    let headphones: Headphones
    @ViewBuilder let accessory: () -> Accessory

    private static var tileSize: CGFloat { 96 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DeviceTile(status: headphones.status, battery: headphones.battery)
                .frame(width: Self.tileSize, height: Self.tileSize)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Label(modelLabel, systemImage: "headphones")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    accessory()
                }
                Text(headphones.name ?? "Bose Headphones")
                    .font(.headline)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if headphones.status == .connected {
                    Facts(battery: headphones.battery, firmware: headphones.firmware)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Self.tileSize, alignment: .top)
        }
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

/// The card's square: the headphones symbol over the battery level.
private struct DeviceTile: View {
    let status: Headphones.Status
    let battery: Int?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            VStack(spacing: 6) {
                Image(systemName: status == .connected ? "headphones" : "headphones.slash")
                    .font(.largeTitle)
                    .foregroundStyle(status == .connected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .symbolEffect(.pulse, options: .repeating, isActive: status == .searching)
                if status == .connected, let battery {
                    Text("\(battery)%")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(battery <= 15 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// "Battery 50% · Firmware 1.6.7", with whatever parts are known.
private struct Facts: View {
    let battery: Int?
    let firmware: String?

    var body: some View {
        HStack(spacing: 4) {
            if let battery {
                Image(systemName: Self.batterySymbol(battery))
                    .foregroundStyle(battery <= 15 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            if let firmware {
                Text("Firmware \(firmware.split(separator: "+").first.map(String.init) ?? firmware)")
                    .help("Firmware \(firmware)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    static func batterySymbol(_ percent: Int) -> String {
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
            Toggle("Announce mode changes", isOn: $headphones.announceModeChanges)
            if let autoPause = headphones.autoPause {
                Toggle("Pause when taken off", isOn: Binding(
                    get: { autoPause }, set: { headphones.setAutoPause($0) }))
            }
            if let autoAnswer = headphones.autoAnswer {
                Toggle("Answer calls when put on", isOn: Binding(
                    get: { autoAnswer }, set: { headphones.setAutoAnswer($0) }))
            }
            Divider()
            if headphones.status == .connected {
                Button("Refresh") { headphones.refresh() }
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

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
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
