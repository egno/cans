import BMAP
import ServiceManagement
import SwiftUI

struct MenuView: View {
    @Bindable var headphones: Headphones

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(headphones: headphones)
            if headphones.status == .connected {
                Divider()
                ModeSection(headphones: headphones)
                EQSection(headphones: headphones)
                Divider()
                SettingsSection(headphones: headphones)
            }
            Divider()
            Footer(headphones: headphones)
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Header

private struct Header: View {
    let headphones: Headphones

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "headphones")
                .font(.title2)
                .foregroundStyle(headphones.status == .connected ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(headphones.name ?? "Bose Headphones").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if headphones.status == .connected, let battery = headphones.battery {
                BatteryView(percent: battery)
            }
        }
    }

    private var subtitle: String {
        switch headphones.status {
        case .searching: "Connecting…"
        case .unavailable: "Not connected"
        case .connected: headphones.firmware.map { "Firmware \($0)" } ?? "Connected"
        }
    }
}

private struct BatteryView: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("\(percent)%").monospacedDigit()
            Image(systemName: symbol)
                .foregroundStyle(percent <= 15 ? .red : .primary)
        }
        .font(.callout)
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

private struct ModeSection: View {
    let headphones: Headphones

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Mode")
            if headphones.modes.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                    ForEach(headphones.modes) { mode in
                        ModeButton(
                            mode: mode,
                            isSelected: headphones.currentMode == mode.index,
                            action: { headphones.selectMode(mode.index) }
                        )
                    }
                }
            }
        }
    }
}

private struct ModeButton: View {
    let mode: ModeSlot
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(mode.name).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(isSelected ? Color.accentColor : Color.primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(mode.name)
    }

    private var symbol: String {
        switch mode.name.lowercased() {
        case "quiet": "ear.badge.waveform"
        case "aware": "ear"
        case "immersion": "dot.radiowaves.left.and.right"
        default: "slider.horizontal.3"
        }
    }
}

// MARK: - EQ

private struct EQSection: View {
    let headphones: Headphones

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("Equalizer")
                Spacer()
                if headphones.eq.contains(where: { $0.value != 0 }) {
                    Button("Reset") {
                        for band in headphones.eq where band.value != 0 {
                            headphones.setEQ(band.kind, value: 0)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            // High frequencies on top, like a mixing console.
            ForEach(headphones.eq.sorted { $0.kind.rawValue > $1.kind.rawValue }) { band in
                EQSlider(band: band) { headphones.setEQ(band.kind, value: $0) }
            }
        }
    }
}

private struct EQSlider: View {
    let band: EQBand
    let commit: (Int) -> Void
    @State private var value: Double = 0
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            Text(band.kind.label).font(.caption).frame(width: 44, alignment: .leading)
            Slider(value: $value,
                   in: Double(band.range.lowerBound)...Double(band.range.upperBound),
                   step: 1) { isEditing in
                editing = isEditing
                if !isEditing, Int(value) != band.value { commit(Int(value)) }
            }
            .controlSize(.small)
            Text(Int(value) > 0 ? "+\(Int(value))" : "\(Int(value))")
                .font(.caption).monospacedDigit()
                .frame(width: 26, alignment: .trailing)
        }
        .onAppear { value = Double(band.value) }
        .onChange(of: band.value) { _, new in if !editing { value = Double(new) } }
    }
}

// MARK: - Settings

private struct SettingsSection: View {
    @Bindable var headphones: Headphones

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let autoPause = headphones.autoPause {
                Toggle("Pause when headphones are removed", isOn: Binding(
                    get: { autoPause }, set: { headphones.setAutoPause($0) }))
            }
            if let autoAnswer = headphones.autoAnswer {
                Toggle("Answer calls by putting them on", isOn: Binding(
                    get: { autoAnswer }, set: { headphones.setAutoAnswer($0) }))
            }
            Toggle("Announce mode changes", isOn: $headphones.announceModeChanges)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.callout)
    }
}

// MARK: - Footer

private struct Footer: View {
    let headphones: Headphones
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = headphones.lastError {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
            HStack {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Spacer()
                if headphones.status == .connected {
                    Button("Refresh") { headphones.refresh() }
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
