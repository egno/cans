import AppKit
import BMAP
import ServiceManagement
import SwiftUI

/// Settings keys shared by the popover and the menu bar label.
enum Prefs {
    static let showBatteryInMenuBar = "showBatteryInMenuBar"
    static let showEqualizer = "showEqualizer"
    static let showDevices = "showDevices"
}

extension View {
    /// `.help` only when there's something to say; an empty tooltip still shows as a blank box.
    @ViewBuilder func help(ifAny text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

struct MenuView: View {
    @Bindable var headphones: Headphones
    @AppStorage(Prefs.showEqualizer) private var showEqualizer = false
    @AppStorage(Prefs.showDevices) private var showDevices = true
    @State private var window: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DeviceCard(headphones: headphones) { SettingsMenu(headphones: headphones) }
                // The text column's spacer would otherwise take whatever height the window offers.
                .fixedSize(horizontal: false, vertical: true)
            if let error = headphones.lastError {
                Banner(text: error) { headphones.dismissError() }
            }
            if headphones.status != .connected {
                DisconnectedPanel(headphones: headphones)
            } else if !headphones.isLoaded {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading settings…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
            } else {
                Divider()
                ModesSection(headphones: headphones)
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
                    VStack(alignment: .leading, spacing: 2) {
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
        .fixedSize(horizontal: false, vertical: true)
        // The menu bar window grows with its content but never shrinks, so after a section
        // collapses it's resized by hand to the content's height.
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { fitWindow(toHeight: $0) }
        .background(WindowReader(window: $window))
        .animation(.snappy(duration: 0.25), value: headphones.currentMode)
        .animation(.snappy(duration: 0.25), value: headphones.status)
        .animation(.snappy(duration: 0.25), value: headphones.isLoaded)
        .animation(.snappy(duration: 0.25), value: headphones.modes)
        .animation(.snappy(duration: 0.25), value: headphones.devices)
        // The list changes when other devices connect, so catch up whenever the popover opens.
        .onAppear { if headphones.status == .connected { headphones.refreshDevices() } }
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

    private var devicesSummary: String {
        "\(headphones.devices.filter(\.isConnected).count) connected"
    }

    /// "Flat", or the bands that aren't at zero: "Bass +8 · Treble −2".
    private var eqSummary: String {
        let changed = headphones.eq.filter { $0.value != 0 }.sorted { $0.kind.rawValue < $1.kind.rawValue }
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
        case .searching: return "Looking for headphones…"
        case .unavailable: return "Not connected"
        case .connected:
            if let mode = headphones.currentModeSlot { return "\(mode.name) mode" }
            // The headphones report no mode until one is set over Bluetooth this session.
            return headphones.isLoaded ? "Mode unknown" : "Connected"
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

// MARK: - Disconnected

/// What to do when the headphones aren't reachable, instead of an empty popover.
private struct DisconnectedPanel: View {
    let headphones: Headphones

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Turn on your headphones, or connect them to this Mac in Bluetooth settings. Cans keeps looking in the background.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(headphones.status == .searching ? "Looking…" : "Try Now") { headphones.retryNow() }
                    .disabled(headphones.status == .searching)
                Button("Bluetooth Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - Modes

/// Presets as tiles, like Control Center's listening modes; custom modes as compact rows below.
private struct ModesSection: View {
    let headphones: Headphones

    /// Slots 0-2 are Quiet, Aware and Immersion; the rest are user modes.
    private var presets: [ModeSlot] { headphones.modes.filter { $0.index < 3 } }
    private var custom: [ModeSlot] { headphones.modes.filter { $0.index >= 3 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Modes")
            if !presets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(presets) { mode in
                        ModeTile(mode: mode, isSelected: headphones.currentMode == mode.index) {
                            headphones.selectMode(mode.index)
                        }
                    }
                }
            }
            if !custom.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(custom) { mode in
                        ModeRow(mode: mode, isSelected: headphones.currentMode == mode.index) {
                            headphones.selectMode(mode.index)
                        }
                    }
                }
            }
        }
    }
}

private struct ModeTile: View {
    let mode: ModeSlot
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    /// Selected is a solid accent fill, like Control Center, so it reads as "on" with any
    /// accent colour, including Graphite.
    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(hovering ? 0.85 : 1)) }
        return hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: mode.symbol)
                    .font(.title3)
                    .frame(height: 22)
                Text(mode.name)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(mode.summary)
        .accessibilityLabel(mode.name)
        .accessibilityHint(mode.summary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ModeRow: View {
    let mode: ModeSlot
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(hovering ? 0.18 : 0.12)) }
        return hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mode.symbol)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(mode.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
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
        .help(ifAny: isSelected ? nil : "Switch to \(mode.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

/// Paired devices. Clicking one connects it; connected ones other than this Mac can be disconnected.
/// When connecting would drop this Mac, and with it Cans' own link, the row asks first.
private struct DeviceList: View {
    let headphones: Headphones
    @State private var confirming: DeviceAddress?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(headphones.devices, id: \.address) { device in
                let dropped = dropped(byConnecting: device)
                DeviceRow(
                    device: device,
                    title: headphones.isThisMac(device) ? "This Mac" : device.name,
                    caption: caption(for: device, dropping: dropped),
                    pending: headphones.pendingDevices[device.address],
                    canConnect: !device.isConnected && headphones.pendingDevices.isEmpty,
                    canDisconnect: device.isConnected && !headphones.isThisMac(device)
                        && headphones.pendingDevices.isEmpty,
                    symbol: symbol(for: device),
                    confirmation: confirming == device.address ? confirmation(for: device) : nil,
                    connect: {
                        if dropped.contains(where: headphones.isThisMac) {
                            confirming = device.address
                        } else {
                            headphones.connect(device)
                        }
                    },
                    confirm: {
                        confirming = nil
                        headphones.connect(device)
                    },
                    cancel: { confirming = nil },
                    disconnect: { headphones.disconnect(device) })
            }
            if let multipoint = headphones.multipoint {
                HStack {
                    Text("Connect to two devices")
                    Spacer()
                    Toggle("Connect to two devices", isOn: Binding(
                        get: { multipoint }, set: { headphones.setMultipoint($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .help(multipoint
                      ? "Stay connected to two devices at once; a third replaces the one not playing"
                      : "Connecting another device disconnects the current one")
            }
        }
    }

    /// Who the headphones will drop to make room: with multipoint, the connected device that
    /// isn't playing (either, if neither is); without it, whatever is connected.
    private func dropped(byConnecting device: DeviceInfo) -> [DeviceInfo] {
        guard !device.isConnected else { return [] }
        let connected = headphones.devices.filter(\.isConnected)
        let limit = headphones.multipoint == false ? 1 : 2
        guard connected.count >= limit else { return [] }
        let inactive = connected.filter { !$0.isActive }
        return inactive.isEmpty ? connected : inactive
    }

    private func caption(for device: DeviceInfo, dropping dropped: [DeviceInfo]) -> String {
        switch headphones.pendingDevices[device.address] {
        case .connect: return "Connecting…"
        case .disconnect: return "Disconnecting…"
        case nil: break
        }
        if device.isConnected { return device.isActive ? "Active" : "Connected" }
        let names = dropped.map(headphones.displayName(of:))
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
        if headphones.isThisMac(device) { return "laptopcomputer" }
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
    let pending: Headphones.PendingChange?
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { if canConnect { connect() } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: symbol)
                            .frame(width: 18)
                            .foregroundStyle(device.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .fontWeight(device.isActive ? .semibold : .regular)
                                .lineLimit(1)
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(device.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(ifAny: canConnect ? "Connect \(device.name)" : nil)
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
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(hovering && canConnect ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
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
                    .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
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
    let headphones: Headphones

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(headphones.eq.sorted { $0.kind.rawValue > $1.kind.rawValue }) { band in
                EQSlider(band: band, revision: headphones.eqRevision) { headphones.setEQ(band.kind, value: $0) }
            }
            HStack {
                Spacer()
                // Always laid out, so the popover doesn't change height when the EQ goes flat.
                Button("Reset to flat") {
                    for band in headphones.eq where band.value != 0 {
                        headphones.setEQ(band.kind, value: 0)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(headphones.eq.allSatisfy { $0.value == 0 })
            }
        }
        .padding(.horizontal, 6)
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
            if headphones.status == .connected {
                Section("Headphones") {
                    if let autoPause = headphones.autoPause {
                        Toggle("Pause when taken off", isOn: Binding(
                            get: { autoPause }, set: { headphones.setAutoPause($0) }))
                    }
                    if let autoAnswer = headphones.autoAnswer {
                        Toggle("Answer calls when put on", isOn: Binding(
                            get: { autoAnswer }, set: { headphones.setAutoAnswer($0) }))
                    }
                    Toggle("Announce mode changes", isOn: $headphones.announceModeChanges)
                    Button("Refresh") { headphones.refresh() }
                }
            }
            Section("Cans") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                Toggle("Show battery in menu bar", isOn: $showBatteryInMenuBar)
                Toggle("Low battery alerts", isOn: $headphones.lowBatteryAlerts)
                Toggle("Hide when disconnected", isOn: $headphones.hideWhenDisconnected)
            }
            Section {
                Text(Self.appVersion)
                if let firmware = headphones.firmware {
                    Text("Headphones firmware \(firmware)")
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
            headphones.showProblem("Couldn't turn \(enabled ? "on" : "off") launch at login: \(error.localizedDescription)")
        }
        if service.status == .requiresApproval {
            headphones.showProblem("Allow Cans in System Settings → General → Login Items to launch at login")
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
            // Taller than the caption text, so the header is easy to hit.
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
