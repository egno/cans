import AppKit
import BMAP
import ServiceManagement
import SwiftUI

/// Settings keys shared by the popover and the menu bar label.
enum Prefs {
    static let showBatteryInMenuBar = "showBatteryInMenuBar"
    static let showEqualizer = "showEqualizer"
    static let showDevices = "showDevices"
    static let showControls = "showControls"
}

extension View {
    /// `.help` only when there's something to say; an empty tooltip still shows as a blank box.
    @ViewBuilder func help(ifAny text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

struct MenuView: View {
    @Bindable var manager: HeadphonesManager
    @AppStorage(Prefs.showEqualizer) private var showEqualizer = false
    @AppStorage(Prefs.showDevices) private var showDevices = true
    @AppStorage(Prefs.showControls) private var showControls = false
    @State private var window: NSWindow?
    /// Address of the pair being renamed, so the row goes when another pair is shown.
    @State private var renaming: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            DeviceCard(manager: manager) {
                SettingsMenu(manager: manager) { renaming = manager.selected?.address }
            }
                // The text column's spacer would otherwise take whatever height the window offers.
                .fixedSize(horizontal: false, vertical: true)
            if let session = manager.selected, renaming == session.address {
                RenameRow(session: session) { renaming = nil }
            }
            if let error = manager.lastError {
                Banner(text: error) { manager.dismissError() }
            }
            if let session = manager.selected {
                // Fresh view state per pair, so a half-done confirmation or an unsent slider
                // position doesn't carry over to the other headphones.
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) { sections(for: session) }
                    .id(session.address)
            } else {
                DisconnectedPanel(manager: manager)
            }
        }
        .padding(14)
        .frame(width: Metrics.width)
        .fixedSize(horizontal: false, vertical: true)
        // The menu bar window grows with its content but never shrinks, so after a section
        // collapses it's resized by hand to the content's height.
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { fitWindow(toHeight: $0) }
        .background(WindowReader(window: $window))
        .animation(.snappy(duration: 0.25), value: manager.selected?.address)
        .animation(.snappy(duration: 0.25), value: manager.selected?.currentMode)
        .animation(.snappy(duration: 0.25), value: manager.selected?.anc)
        .animation(.snappy(duration: 0.25), value: manager.status)
        .animation(.snappy(duration: 0.25), value: manager.selected?.isLoaded)
        .animation(.snappy(duration: 0.25), value: manager.selected?.modes)
        .animation(.snappy(duration: 0.25), value: manager.selected?.devices)
        .animation(.snappy(duration: 0.25), value: manager.audio.defaultOutput)
        .animation(.snappy(duration: 0.25), value: manager.absentPairs)
        // The menu bar window is reused, so appear/disappear may not fire on every open;
        // its key state does. The manager ignores repeats.
        .onAppear { manager.popoverDidOpen() }
        .onDisappear { manager.popoverDidClose() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            if let window, $0.object as? NSWindow === window { manager.popoverDidOpen() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
            if let window, $0.object as? NSWindow === window { manager.popoverDidClose() }
        }
    }

    /// Only what this model supports, once it has been read.
    @ViewBuilder private func sections(for session: HeadphoneSession) -> some View {
        let profile = session.profile
        if !session.isLoaded {
            Divider()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading settings…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Metrics.inset)
        } else {
            if let layout = session.modeLayout, !session.modes.isEmpty {
                PanelSection(title: "Modes") { ModesSection(session: session, layout: layout) }
            }
            if case .ancLevels(let defaults) = profile.noiseControl, profile.supports(.ancLevel), let anc = session.anc {
                PanelSection(title: "Noise Cancelling") {
                    NoiseCancellingSection(session: session, levels: anc.supported.isEmpty ? defaults : anc.supported)
                }
            }
            if profile.supports(.pairedDevices), !session.devices.isEmpty {
                PanelSection(title: "Devices", detail: devicesSummary(session), isExpanded: $showDevices) {
                    DeviceList(session: session, thisMacOnly: manager.thisMacOnly)
                }
            }
            if profile.supports(.eq), !session.eq.isEmpty {
                PanelSection(title: "Equalizer", detail: eqSummary(session), isExpanded: $showEqualizer) {
                    EQPanel(session: session, presets: manager.eqPresets)
                }
            }
            if session.hasControls {
                PanelSection(title: "Controls", detail: controlsSummary(session), isExpanded: $showControls) {
                    ControlsPanel(manager: manager, session: session)
                }
            }
        }
    }

    /// Keeps the top edge where it is, under the menu bar, and moves the bottom.
    private func fitWindow(toHeight height: CGFloat) {
        guard let window else { return }
        let contentHeight = window.contentRect(forFrameRect: window.frame).height
        guard abs(contentHeight - height) > 0.5 else { return }
        var frame = window.frame
        let newHeight = frame.height - contentHeight + height
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight
        window.setFrame(frame, display: true)
    }

    private func devicesSummary(_ session: HeadphoneSession) -> String {
        "\(session.devices.filter(\.isConnected).count) connected"
    }

    /// The matching preset's name ("Flat"), or the bands that aren't at zero: "Bass +8 · Treble −2".
    private func eqSummary(_ session: HeadphoneSession) -> String {
        if let preset = manager.eqPresets.match(session.eq) { return preset.name }
        let changed = session.eq.filter { $0.value != 0 }.sorted { $0.kind.rawValue < $1.kind.rawValue }
        guard !changed.isEmpty else { return "Flat" }
        return changed.map { "\($0.kind.label) \(signed($0.value))" }.joined(separator: " · ")
    }
}

/// Hands back the NSWindow hosting the popover.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window !== view.window { DispatchQueue.main.async { window = view.window } }
    }
}

/// Sizes every section shares, so rows, tiles and headers line up.
enum Metrics {
    /// Popover width.
    static let width: CGFloat = 320
    /// Gap between sections, and around their dividers.
    static let sectionSpacing: CGFloat = 12
    /// Text and controls sit this far in from the popover padding; rows fill it with their highlight.
    static let inset: CGFloat = 6
    static let rowRadius: CGFloat = 6
    static let tileRadius: CGFloat = 8
    /// Width of a row's leading symbol.
    static let symbolWidth: CGFloat = 18
    /// Gap between a row's symbol and its text.
    static let symbolGap: CGFloat = 10
}

private func signed(_ v: Int) -> String {
    v > 0 ? "+\(v)" : v < 0 ? "−\(-v)" : "0"
}

// MARK: - Device card

/// Name, mode and battery of the shown headphones: a compact version of progradio's now-playing card.
/// With more than one pair the name becomes a menu for switching between them.
private struct DeviceCard<Accessory: View>: View {
    let manager: HeadphonesManager
    @ViewBuilder let accessory: () -> Accessory

    private var session: HeadphoneSession? { manager.selected }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(modelLabel, systemImage: session != nil ? "headphones" : "headphones.slash")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(session != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let session, let battery = session.battery {
                    BatteryLabel(percent: battery, isLow: session.isBatteryLow, minutesLeft: session.batteryMinutes)
                }
                accessory()
            }
            if let session, manager.sessions.count > 1 || !manager.absentPairs.isEmpty {
                PairPicker(manager: manager, selected: session)
            } else {
                Text(session?.displayName ?? "Bose Headphones")
                    .font(.headline)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let session {
                    Spacer(minLength: 6)
                    MacAudioControl(manager: manager, session: session)
                }
            }
        }
        .padding(.horizontal, Metrics.inset)
    }

    private var modelLabel: String {
        let model = session.map { $0.modelName.replacingOccurrences(of: "Bose ", with: "") } ?? "Headphones"
        return model.uppercased()
    }

    private var statusLine: String {
        guard let session else {
            return manager.status == .searching ? "Looking for headphones…" : "Not connected"
        }
        if session.isPoweringOff { return "Turning off…" }
        // QC Ultra reports no mode until one is set over Bluetooth this session.
        return session.noiseControlSummary ?? "Connected"
    }
}

/// The shown pair's name as a menu of every connected pair with its battery level.
/// Pairs Cans knows but can't reach are listed too, so it's clear they weren't forgotten.
private struct PairPicker: View {
    let manager: HeadphonesManager
    let selected: HeadphoneSession

    var body: some View {
        Menu {
            Picker("Headphones", selection: Binding(
                get: { selected.address },
                set: { address in manager.sessions.first { $0.address == address }.map(manager.select) })) {
                ForEach(manager.sessions, id: \.address) { session in
                    Group {
                        if manager.isPlayingHere(session) {
                            Label(title(for: session), systemImage: "speaker.wave.2.fill")
                        } else {
                            Text(title(for: session))
                        }
                    }
                    .tag(session.address)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            let elsewhere = manager.sessions.filter { !manager.isPlayingHere($0) }
            if !elsewhere.isEmpty {
                Section("Mac Audio") {
                    ForEach(elsewhere, id: \.address) { session in
                        Button("Play on \(session.displayName)") { manager.playHere(session) }
                            .disabled(!manager.canPlayHere(session))
                            .help(manager.canPlayHere(session)
                                  ? "Play this Mac's sound on \(session.displayName)"
                                  : "Connect \(session.displayName) to this Mac for audio in Bluetooth settings")
                    }
                }
            }
            if !manager.absentPairs.isEmpty {
                Section("Not Connected") {
                    ForEach(manager.absentPairs) { pair in
                        let connecting = manager.connectingPairs.contains(pair.address)
                        Button("\(pair.name) · \(absentCaption(connecting: connecting, status: manager.status))") {
                            manager.connect(pair)
                        }
                        .disabled(connecting)
                        .help("Connect \(pair.name)")
                    }
                }
            }
        } label: {
            Text(selected.displayName)
                .font(.headline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch headphones")
        .accessibilityLabel("Headphones, \(selected.displayName)")
    }

    /// "High Note · 12% (low)"
    private func title(for session: HeadphoneSession) -> String {
        guard let battery = session.battery else { return session.displayName }
        return "\(session.displayName) · \(battery)%\(session.isBatteryLow ? " (low)" : "")"
    }
}

/// Where the Mac's sound goes, for the shown pair: a speaker when it plays there, a link
/// to send it there when the pair is connected to this Mac for audio, otherwise nothing.
private struct MacAudioControl: View {
    let manager: HeadphonesManager
    let session: HeadphoneSession

    var body: some View {
        if manager.isPlayingHere(session) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(.tint)
                .help("This Mac's sound plays on \(session.displayName)")
                .accessibilityLabel("Mac audio plays on \(session.displayName)")
        } else if manager.canPlayHere(session) {
            Button { manager.playHere(session) } label: {
                Label("Play Mac audio", systemImage: "speaker.wave.2")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.link)
            .font(.caption)
            .help("Play this Mac's sound on \(session.displayName)")
            .accessibilityLabel("Play Mac audio on \(session.displayName)")
        }
    }
}

/// "60%" with a battery symbol; red when low.
private struct BatteryLabel: View {
    let percent: Int
    let isLow: Bool
    var minutesLeft: Int?

    var body: some View {
        HStack(spacing: 3) {
            Text("\(percent)%").monospacedDigit()
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(isLow ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .help("Battery \(percent)%" + (minutesLeft.map { ", about \(playTimeLabel(minutes: $0)) left" } ?? ""))
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

// MARK: - Disconnected

/// What to do when the headphones aren't reachable, instead of an empty popover:
/// the pairs Cans knows, each with Connect, or a hint when it knows none.
private struct DisconnectedPanel: View {
    let manager: HeadphonesManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if manager.absentPairs.isEmpty {
                Text("Turn on your headphones, or connect them to this Mac in Bluetooth settings. Cans keeps looking in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.inset)
                HStack(spacing: 8) {
                    Button(manager.status == .searching ? "Looking…" : "Try Now") { manager.retryNow() }
                        .disabled(manager.status == .searching)
                    bluetoothSettings
                }
                .controlSize(.small)
                .padding(.horizontal, Metrics.inset)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(manager.absentPairs) { pair in
                        let connecting = manager.connectingPairs.contains(pair.address)
                        AbsentPairRow(pair: pair, isConnecting: connecting,
                                      caption: absentCaption(connecting: connecting, status: manager.status)) {
                            manager.connect(pair)
                        }
                    }
                }
                HStack {
                    Text("Cans connects on its own when they turn on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    bluetoothSettings
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.horizontal, Metrics.inset)
            }
        }
    }

    private var bluetoothSettings: some View {
        Button("Bluetooth Settings…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
        }
    }
}

/// "Connecting…" for a pair the user asked for, "Looking…" while a search may still find it,
/// otherwise a neutral "Not connected": Cans can't tell off from out of reach.
func absentCaption(connecting: Bool, status: HeadphonesManager.Status) -> String {
    if connecting { return "Connecting…" }
    return status == .searching ? "Looking…" : "Not connected"
}

/// A known pair that isn't connected.
private struct AbsentPairRow: View {
    let pair: HeadphonesManager.AbsentPair
    let isConnecting: Bool
    let caption: String
    let connect: () -> Void

    var body: some View {
        ListRow(symbol: "headphones", title: pair.name, caption: caption) {
            if isConnecting {
                ProgressView().controlSize(.small)
            } else {
                Button("Connect", action: connect)
                    .controlSize(.small)
                    .help("Ask \(pair.name) to connect to this Mac")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pair.name), \(caption)")
        .accessibilityActions {
            if !isConnecting { Button("Connect", action: connect) }
        }
    }
}

// MARK: - Modes

/// Presets as tiles, like Control Center's listening modes; custom modes as compact rows below.
private struct ModesSection: View {
    let session: HeadphoneSession
    let layout: ModeLayout
    /// The custom mode being created, changed or deleted, in a form under the list.
    @State private var editing: ModeEditing?

    /// Built-in modes take the first slots; the rest are user modes.
    private var presets: [ModeSlot] { session.modes.filter { Int($0.index) < layout.presetCount } }
    private var custom: [ModeSlot] { session.modes.filter { Int($0.index) >= layout.presetCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !presets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(presets) { mode in
                        let preset = layout.preset(at: mode.index)
                        ChoiceTile(title: mode.name, symbol: preset.symbol, summary: preset.summary,
                                   isSelected: session.currentMode == mode.index) {
                            session.selectMode(mode.index)
                        }
                    }
                }
                // Custom modes are rows with their own names; only presets need explaining.
                if let mode = session.currentModeSlot, presets.contains(mode) {
                    TileCaption(text: layout.preset(at: mode.index).summary)
                }
            }
            if !custom.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(custom) { mode in
                        let isSelected = session.currentMode == mode.index
                        ListRow(symbol: layout.preset(at: mode.index).symbol, title: mode.name,
                                isSelected: isSelected, help: isSelected ? nil : "Switch to \(mode.name)",
                                action: { session.selectMode(mode.index) }) {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                            if let config = session.modeConfig(at: mode.index), session.canEdit(config) {
                                ModeRowMenu(session: session, config: config, editing: $editing)
                            }
                        }
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            ModeExtras(session: session, editing: $editing)
        }
    }
}

/// Fixed noise cancelling levels, for models without modes.
private struct NoiseCancellingSection: View {
    let session: HeadphoneSession
    let levels: [ANCLevel]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(levels, id: \.self) { level in
                    ChoiceTile(title: level.label, symbol: level.symbol, summary: level.summary,
                               isSelected: session.anc?.level == level,
                               accessibilityTitle: "Noise cancelling \(level.label.lowercased())") {
                        session.setANC(level)
                    }
                }
            }
            if let level = session.anc?.level {
                TileCaption(text: level.summary)
            }
        }
    }
}

/// What the selected tile does, in a line under the tiles.
private struct TileCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, Metrics.inset)
            .contentTransition(.opacity)
    }
}

extension ANCLevel {
    /// One circle filling up from Off to High, so the tiles read as a scale; Wind is
    /// a different kind of setting and looks it.
    var symbol: String {
        switch self {
        case .off: "circle.dotted"
        case .low: "circle.lefthalf.filled"
        case .high: "circle.fill"
        case .wind: "wind"
        }
    }

    var summary: String {
        switch self {
        case .off: "Hear everything around you"
        case .low: "Blocks some noise"
        case .high: "Blocks the most noise"
        case .wind: "Blocks noise and cuts wind rumble"
        }
    }
}

/// A large toggle tile: selected is a solid accent fill, like Control Center, so it reads as
/// "on" with any accent colour, including Graphite.
private struct ChoiceTile: View {
    let title: String
    let symbol: String
    let summary: String
    let isSelected: Bool
    /// When the title alone is ambiguous out of context ("Off").
    var accessibilityTitle: String?
    let action: () -> Void
    @State private var hovering = false

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(hovering ? 0.85 : 1)) }
        return hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(height: 22)
                Text(title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: Metrics.tileRadius).fill(background))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(summary)
        .accessibilityLabel(accessibilityTitle ?? title)
        .accessibilityHint(summary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The one row style for lists: a symbol, a title with an optional caption, and something
/// trailing. The selected row is tinted; a row that does something lights up under the pointer.
struct ListRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var caption: String?
    var isSelected = false
    var help: String?
    /// Nil when clicking does nothing: the row then isn't a button, so the pointer and
    /// VoiceOver don't promise a click.
    var action: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovering = false

    private var tint: AnyShapeStyle { isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary) }

    private var background: AnyShapeStyle {
        let lit = hovering && action != nil
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(lit ? 0.18 : 0.12)) }
        return lit ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
    }

    var body: some View {
        HStack(spacing: Metrics.symbolGap) {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
                    .help(ifAny: help)
            } else {
                label
            }
            trailing()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, Metrics.inset)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(background))
        .onHover { hovering = $0 }
    }

    private var label: some View {
        HStack(spacing: Metrics.symbolGap) {
            Image(systemName: symbol)
                .frame(width: Metrics.symbolWidth)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Devices

/// Paired devices. Clicking one connects it; connected ones other than this Mac can be disconnected.
/// When connecting would drop this Mac, and with it Cans' own link, the row asks first.
private struct DeviceList: View {
    let session: HeadphoneSession
    let thisMacOnly: ThisMacOnly
    @State private var confirming: DeviceAddress?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NowPlayingRow(session: session)
            ForEach(session.devices, id: \.address) { device in
                let dropped = dropped(byConnecting: device)
                DeviceRow(
                    device: device,
                    title: session.isThisMac(device) ? "This Mac" : device.name,
                    caption: caption(for: device, dropping: dropped),
                    pending: session.pendingDevices[device.address],
                    canConnect: !device.isConnected && session.pendingDevices.isEmpty,
                    canDisconnect: device.isConnected && !session.isThisMac(device)
                        && session.pendingDevices.isEmpty,
                    symbol: symbol(for: device),
                    confirmation: confirming == device.address ? confirmation(for: device) : nil,
                    connect: {
                        if dropped.contains(where: session.isThisMac) {
                            confirming = device.address
                        } else {
                            session.connect(device)
                        }
                    },
                    confirm: {
                        confirming = nil
                        session.connect(device)
                    },
                    cancel: { confirming = nil },
                    disconnect: { session.disconnect(device) })
            }
            ThisMacOnlyRow(session: session, store: thisMacOnly)
            AudioRouteRow(session: session)
            if session.profile.supports(.multipoint), let multipoint = session.multipoint {
                ControlRow(title: "Connect to two devices",
                           help: multipoint
                               ? "Stay connected to two devices at once; a third replaces the one not playing"
                               : "Connecting another device disconnects the current one") {
                    Toggle("Connect to two devices", isOn: Binding(
                        get: { multipoint }, set: { session.setMultipoint($0) }))
                }
                .padding(.horizontal, Metrics.inset)
                .padding(.top, 4)
            }
        }
    }

    /// Who the headphones will drop to make room: with multipoint, the connected device that
    /// isn't playing (either, if neither is); without it, whatever is connected.
    private func dropped(byConnecting device: DeviceInfo) -> [DeviceInfo] {
        guard !device.isConnected else { return [] }
        let connected = session.devices.filter(\.isConnected)
        let limit = session.multipoint == false ? 1 : 2
        guard connected.count >= limit else { return [] }
        let inactive = connected.filter { !$0.isActive }
        return inactive.isEmpty ? connected : inactive
    }

    private func caption(for device: DeviceInfo, dropping dropped: [DeviceInfo]) -> String {
        switch session.pendingDevices[device.address] {
        case .connect: return "Connecting…"
        case .disconnect: return "Disconnecting…"
        case nil: break
        }
        if device.isConnected {
            if session.playingDevice?.address == device.address { return "Playing" }
            return device.isActive ? "Active" : "Connected"
        }
        let names = dropped.map(session.displayName(of:))
        switch names.count {
        case 0: return "Not connected"
        case 1: return "Replaces \(names[0])"
        default: return "Replaces \(names.dropLast().joined(separator: ", ")) or \(names.last!)"
        }
    }

    private func confirmation(for device: DeviceInfo) -> String {
        "Connecting \(device.name) disconnects the headphones from this Mac, so Cans will lose them too."
    }

    private func symbol(for device: DeviceInfo) -> String {
        if session.isThisMac(device) { return "laptopcomputer" }
        let name = device.name.lowercased()
        let words = Set(name.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let has = { (keys: [String]) in keys.contains { words.contains($0) } }
        if name.contains("macbook") { return "laptopcomputer" }
        if ["imac", "mac mini", "mac studio", "mac pro"].contains(where: name.contains) { return "desktopcomputer" }
        if name.contains("ipad") { return "ipad" }
        if name.contains("iphone") { return "iphone" }
        if name.contains("watch") { return "applewatch" }
        if name.contains("apple tv") || has(["tv", "bravia"]) { return "tv" }
        if has(["phone", "galaxy", "pixel", "oneplus", "xiaomi", "redmi", "moto", "motorola", "edge",
                "nokia", "huawei", "honor", "oppo", "vivo", "realme", "nothing"]) { return "smartphone" }
        if has(["pc", "laptop", "desktop", "thinkpad", "surface", "windows", "dell", "lenovo", "hp", "asus"]) {
            return "pc"
        }
        return "dot.radiowaves.left.and.right"
    }
}

private struct DeviceRow: View {
    let device: DeviceInfo
    let title: String
    let caption: String
    let pending: HeadphoneSession.PendingChange?
    let canConnect: Bool
    let canDisconnect: Bool
    let symbol: String
    let confirmation: String?
    let connect: () -> Void
    let confirm: () -> Void
    let cancel: () -> Void
    let disconnect: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ListRow(symbol: symbol, title: title, caption: caption, isSelected: device.isActive,
                    help: "Connect \(device.name)", action: canConnect ? connect : nil) {
                trailing
            }
            if let confirmation {
                VStack(alignment: .leading, spacing: 6) {
                    Text(confirmation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Connect Anyway", action: confirm)
                        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    }
                    .controlSize(.small)
                }
                // Under the row's text.
                .padding(.leading, Metrics.inset + Metrics.symbolWidth + Metrics.symbolGap)
                .padding(.bottom, 6)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if canConnect { Button("Connect", action: connect) }
            if canDisconnect { Button("Disconnect", action: disconnect) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(caption)")
        .accessibilityAddTraits(device.isActive ? .isSelected : [])
        .accessibilityActions {
            if canConnect { Button("Connect", action: connect) }
            if canDisconnect { Button("Disconnect", action: disconnect) }
        }
    }

    @ViewBuilder private var trailing: some View {
        if pending != nil {
            ProgressView().controlSize(.small)
        } else if canDisconnect {
            // Always visible so it's discoverable; brighter under the pointer.
            Button(action: disconnect) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help("Disconnect \(device.name)")
        } else if device.isConnected {
            Circle().fill(device.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 6, height: 6)
                .padding(.trailing, 4)
        }
    }
}

// MARK: - Equalizer

/// Treble on top, like a mixing console.
private struct EQPanel: View {
    let session: HeadphoneSession
    let presets: EQPresetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EQPresetBar(session: session, store: presets)
            ForEach(session.eq.sorted { $0.kind.rawValue > $1.kind.rawValue }) { band in
                EQSlider(band: band, revision: session.eqRevision) { session.setEQ(band.kind, value: $0) }
            }
            HStack {
                Spacer()
                // Always laid out, so the popover doesn't change height when the EQ goes flat.
                Button("Reset to flat") {
                    for band in session.eq where band.value != 0 {
                        session.setEQ(band.kind, value: 0)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(session.eq.allSatisfy { $0.value == 0 })
            }
        }
        .padding(.horizontal, Metrics.inset)
    }
}

/// Sends while dragging (at most every 100 ms) so the change can be heard, and gives a
/// haptic bump and a tick mark at 0. Arrow keys and VoiceOver go through the same path.
private struct EQSlider: View {
    let band: EQBand
    /// Changes when a write failed; the slider then returns to the headphones' value.
    let revision: Int
    let commit: (Int) -> Void
    @State private var value: Double = 0
    @State private var editing = false
    /// Last value sent and not yet confirmed by the headphones.
    @State private var sent: Int?
    @State private var sendTask: Task<Void, Never>?

    private var range: ClosedRange<Double> { Double(band.range.lowerBound)...Double(band.range.upperBound) }

    var body: some View {
        HStack(spacing: 8) {
            Text(band.kind.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Slider(value: $value, in: range, step: 1) { isEditing in
                editing = isEditing
                if !isEditing { flush() }
            }
            .controlSize(.small)
            .background(alignment: .bottom) { zeroTick }
            .accessibilityLabel(band.kind.label)
            .accessibilityValue(signed(Int(value)))
            Button { value = 0; flush() } label: {
                Text(signed(Int(value)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help(ifAny: Int(value) != 0 ? "Reset \(band.kind.label.lowercased()) to 0" : nil)
            .accessibilityHidden(true)
        }
        .onAppear { value = Double(band.value) }
        .onChange(of: value) { old, new in
            if editing, Int(new) == 0, Int(old) != 0 {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            scheduleSend()
        }
        .onChange(of: band.value) { _, new in
            sent = nil
            if !editing && sendTask == nil { value = Double(new) }
        }
        .onChange(of: revision) {
            sendTask?.cancel()
            sendTask = nil
            sent = nil
            value = Double(band.value)
        }
    }

    /// A short mark under the track where 0 is. The small slider's knob keeps about 7 pt from each end.
    private var zeroTick: some View {
        GeometryReader { geo in
            let inset = 7.0
            let fraction = (0 - range.lowerBound) / (range.upperBound - range.lowerBound)
            Rectangle()
                .fill(.tertiary)
                .frame(width: 1, height: 4)
                .position(x: inset + fraction * (geo.size.width - 2 * inset), y: geo.size.height - 1)
        }
        .allowsHitTesting(false)
    }

    /// The last confirmed or sent value, so the same value isn't sent twice.
    private var known: Int { sent ?? band.value }

    private func scheduleSend() {
        guard Int(value) != known, sendTask == nil else { return }
        sendTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            sendTask = nil
            flush()
        }
    }

    private func flush() {
        sendTask?.cancel()
        sendTask = nil
        let target = Int(value)
        guard target != known else { return }
        sent = target
        commit(target)
    }
}

// MARK: - Controls

/// Per-headphone settings, each only where the model has it. Voice prompts are shown here
/// only where they can't be changed (their write is unconfirmed on a QC35 II); where they
/// can, they're in the gear menu with the other rarely used settings.
private struct ControlsPanel: View {
    @Bindable var manager: HeadphonesManager
    let session: HeadphoneSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if session.profile.supports(.autoPause), let autoPause = session.autoPause {
                ControlRow(title: "Pause when taken off", help: "Pause playback when you take the headphones off") {
                    Toggle("Pause when taken off", isOn: Binding(get: { autoPause }, set: { session.setAutoPause($0) }))
                }
            }
            if session.profile.supports(.autoAnswer), let autoAnswer = session.autoAnswer {
                ControlRow(title: "Answer calls when put on", help: "Answer an incoming call when you put the headphones on") {
                    Toggle("Answer calls when put on",
                           isOn: Binding(get: { autoAnswer }, set: { session.setAutoAnswer($0) }))
                }
            }
            // Announcing is a flag on the mode switch request, kept by Cans.
            if session.modeLayout != nil {
                ControlRow(title: "Announce mode changes", help: "The headphones say the new mode's name when Cans switches it") {
                    Toggle("Announce mode changes", isOn: $manager.announceModeChanges)
                }
            }
            CallModeRow(session: session, calls: manager.callSwitch)
            if session.profile.supports(.sidetone), let sidetone = session.sidetone {
                ControlRow(title: "Self voice", help: "How much of your own voice you hear on calls") {
                    Picker("Self voice", selection: Binding(
                        get: { sidetone.level }, set: { $0.map(session.setSidetone) })) {
                        ForEach(sidetoneOptions(sidetone), id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                }
            }
            if session.profile.supports(.actionButton), let button = session.actionButton {
                ControlRow(title: button.buttonName, help: "What a \(button.eventName) of the \(button.buttonName) does") {
                    Picker(button.buttonName, selection: Binding(
                        get: { button.action }, set: { session.setActionButton($0) })) {
                        ForEach(actionOptions(button), id: \.self) { Text($0.label).tag($0) }
                    }
                }
            }
            if session.profile.supports(.autoOff), let autoOff = session.autoOff {
                ControlRow(title: "Turn off when idle", help: "Power off after this long without audio") {
                    Picker("Turn off when idle", selection: Binding(
                        get: { autoOff }, set: { session.setAutoOff(minutes: $0) })) {
                        ForEach(options(AutoOff.choices.map(Int.init), current: autoOff), id: \.self) {
                            Text(autoOffLabel(minutes: $0)).tag($0)
                        }
                    }
                }
            }
            if session.profile.supports(.voicePrompts), !session.canChangeVoicePrompts, let prompts = session.voicePrompts {
                ControlRow(title: "Voice prompts", help: "Spoken announcements; can't be changed here yet") {
                    Text(voicePromptsLabel(prompts))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 2)
                }
            }
        }
        .padding(.horizontal, Metrics.inset)
    }

    /// Weakest to strongest, like the noise cancelling tiles.
    private func sidetoneOptions(_ state: SidetoneState) -> [SidetoneLevel] {
        options([.off, .low, .medium, .high].filter(state.supported.contains), current: state.level)
    }

    /// Actions the device can take right now; unavailable ones are left out unless current.
    private func actionOptions(_ state: ActionButtonState) -> [ButtonAction] {
        options(state.supported.filter { !state.unavailable.contains($0) }, current: state.action)
    }

    /// The supported values, plus the current one if the device reports something outside them.
    private func options<T: Equatable>(_ supported: [T], current: T?) -> [T] {
        guard let current, !supported.contains(current) else { return supported }
        return supported + [current]
    }
}

/// A caption label with a compact control on the right: the label in primary, the value
/// in secondary, so the eye lands on what each row is.
struct ControlRow<Control: View>: View {
    let title: String
    let help: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            control()
                .labelsHidden()
                .pickerStyle(.menu)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .font(.caption)
        .frame(minHeight: 22)
        .help(help)
    }
}

/// The two most telling values for the collapsed header, from whichever settings the
/// model has, in this order: "Self voice low · Off after 20 min", "Auto-pause on · Auto-answer off".
@MainActor
func controlsSummary(_ session: HeadphoneSession) -> String? {
    let profile = session.profile
    var parts: [String] = []
    if profile.supports(.sidetone), let level = session.sidetone?.level {
        parts.append("Self voice \(level.label.lowercased())")
    }
    if profile.supports(.autoOff), let minutes = session.autoOff {
        parts.append(minutes == 0 ? "Stays on" : "Off after \(autoOffLabel(minutes: minutes))")
    }
    if profile.supports(.autoPause), let on = session.autoPause {
        parts.append("Auto-pause \(on ? "on" : "off")")
    }
    if profile.supports(.autoAnswer), let on = session.autoAnswer {
        parts.append("Auto-answer \(on ? "on" : "off")")
    }
    if profile.supports(.actionButton), let action = session.actionButton?.action {
        parts.append("Button: \(action.label)")
    }
    return parts.isEmpty ? nil : parts.prefix(2).joined(separator: " · ")
}

/// "Never", "20 min", "1 hour", "3 hours".
func autoOffLabel(minutes: Int) -> String {
    switch minutes {
    case 0: "Never"
    case 60: "1 hour"
    case let m where m > 60 && m % 60 == 0: "\(m / 60) hours"
    default: "\(minutes) min"
    }
}

/// "On · US English", or "Off".
func voicePromptsLabel(_ prompts: VoicePrompts) -> String {
    guard prompts.isOn else { return "Off" }
    return prompts.languageName.map { "On · \($0)" } ?? "On"
}

// MARK: - Settings

/// Set-once options and links, kept out of the way in a gear menu: the app's own, and the
/// shown headphones' rarely used ones.
private struct SettingsMenu: View {
    @Bindable var manager: HeadphonesManager
    /// Opens the row for typing a new name; a menu can't hold a text field.
    let rename: () -> Void
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
            if let session = manager.selected, session.isLoaded {
                HeadphoneMenuItems(session: session, rename: rename)
            }
            // App settings; the headphones' everyday ones are in the Controls section.
            Section("Cans") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                Toggle("Show battery in menu bar", isOn: $showBatteryInMenuBar)
                Toggle("Low battery alerts", isOn: $manager.lowBatteryAlerts)
                Toggle("Hide when disconnected", isOn: $manager.hideWhenDisconnected)
            }
            Section {
                Text(Self.appVersion)
                if let firmware = manager.selected?.firmware {
                    Text("Headphones firmware \(firmware)")
                }
                if let session = manager.selected, session.profile.supports(.serialNumber),
                   let serial = session.serial, !serial.isEmpty {
                    Button("Copy Serial Number \(serial)") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(serial, forType: .string)
                    }
                }
                Button("Send Feedback…") { NSWorkspace.shared.open(URL(string: "https://github.com/egno/cans/issues")!) }
            }
            Section {
                Button("Quit Cans") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Settings")
        .accessibilityLabel("Settings")
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            manager.showProblem("Couldn't turn \(enabled ? "on" : "off") launch at login: \(error.localizedDescription)")
        }
        if service.status == .requiresApproval {
            manager.showProblem("Allow Cans in System Settings → General → Login Items to launch at login")
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = service.status == .enabled
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
                // Two lines may cut it off.
                .help(text)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(.red.opacity(0.1)))
    }
}

/// One block of the popover: a divider, a caption header and the content. With `isExpanded`
/// the header shows and hides the content.
private struct PanelSection<Content: View>: View {
    let title: String
    var detail: String?
    var isExpanded: Binding<Bool>?
    @ViewBuilder let content: () -> Content

    var body: some View {
        Divider()
        if let isExpanded {
            VStack(alignment: .leading, spacing: 2) {
                SectionToggle(title: title, detail: detail, isExpanded: isExpanded)
                if isExpanded.wrappedValue { content() }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: title, detail: detail)
                content()
            }
        }
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
        .padding(.horizontal, Metrics.inset)
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
                    .padding(.trailing, Metrics.inset)
            }
            // Taller than the caption text, so the header is easy to hit.
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
