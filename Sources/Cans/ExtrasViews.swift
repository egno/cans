import BMAP
import SwiftUI

// Popover pieces for the features that live in their own files: equalizer presets,
// "This Mac Only" and the mode for calls. `MenuView` only places them.

// MARK: - Equalizer presets

/// The preset the equalizer is on, as a menu of all of them, with saving, renaming and
/// deleting the user's own. Names are typed in a row that opens underneath: a menu bar
/// popover closes under an alert.
struct EQPresetBar: View {
    let session: HeadphoneSession
    let store: EQPresetStore

    private enum Editing: Equatable {
        case saving
        case renaming(EQPreset)
    }

    @State private var editing: Editing?
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var current: EQPreset? { store.match(session.eq) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Preset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                menu
                Spacer(minLength: 0)
            }
            if let editing {
                HStack(spacing: 6) {
                    TextField("Preset name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(commit)
                        .accessibilityLabel(editing == .saving ? "Name for the new preset" : "New name for the preset")
                    Button(editing == .saving ? "Save" : "Rename", action: commit)
                        .disabled(!canCommit)
                        .help(ifAny: commitProblem)
                    Button("Cancel") { self.editing = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .controlSize(.small)
                .onAppear { nameFocused = true }
            }
        }
        .padding(.bottom, 2)
    }

    private var menu: some View {
        Menu {
            ForEach(EQPresetStore.builtIn) { item($0) }
            if !store.custom.isEmpty {
                Section("Saved") {
                    ForEach(store.custom) { item($0) }
                }
            }
            Divider()
            Button("Save as Preset…") { begin(.saving, name: "") }
                .disabled(current != nil)
            if !store.custom.isEmpty {
                Menu("Rename") {
                    ForEach(store.custom) { preset in
                        Button("\(preset.name)…") { begin(.renaming(preset), name: preset.name) }
                    }
                }
                Menu("Delete") {
                    ForEach(store.custom) { preset in
                        Button(preset.name, role: .destructive) { store.delete(preset.id) }
                    }
                }
            }
        } label: {
            Text(current?.name ?? "Custom")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(current.map { "\($0.name): \($0.summary)" } ?? "The equalizer matches no preset; save it as one")
        .accessibilityLabel("Equalizer preset, \(current?.name ?? "custom")")
    }

    /// Checked when the equalizer is on it.
    private func item(_ preset: EQPreset) -> some View {
        Toggle(preset.name, isOn: Binding(
            get: { current?.id == preset.id },
            set: { _ in session.apply(preset) }))
            .help(preset.summary)
    }

    private func begin(_ editing: Editing, name: String) {
        self.name = name
        self.editing = editing
    }

    private var canCommit: Bool {
        switch editing {
        case .saving:
            // Saving over one of the user's own presets is how it's updated.
            let taken = store.preset(named: name).map(store.isBuiltIn) ?? false
            return !name.trimmingCharacters(in: .whitespaces).isEmpty && !taken
        case .renaming(let preset): return store.canUse(name: name, for: preset.id)
        case nil: return false
        }
    }

    private var commitProblem: String? {
        guard !canCommit, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return "There's already a preset with this name"
    }

    private func commit() {
        guard canCommit else { return }
        switch editing {
        case .saving: store.save(name: name, bands: session.eq)
        case .renaming(let preset): store.rename(preset.id, to: name)
        case nil: break
        }
        editing = nil
    }
}

// MARK: - This Mac only

/// Under the device list: a link that disconnects the other devices, shown only while one
/// is connected, and afterwards one that brings them back.
struct ThisMacOnlyRow: View {
    let session: HeadphoneSession
    let store: ThisMacOnly

    var body: some View {
        let others = store.others(of: session)
        let back = store.reconnectable(for: session)
        // Always there, even when empty, so the device list is followed while the row is hidden.
        VStack(spacing: 0) {
            if !others.isEmpty {
                link("This Mac Only", help: "Disconnect \(listed(others.map(\.name))), so the headphones stay with this Mac") {
                    store.engage(session)
                }
            } else if !back.isEmpty {
                link("Reconnect \(listed(back.map(\.name)))",
                     help: "Connect \(listed(back.map(\.name))) again, alongside this Mac") {
                    store.reconnect(session)
                }
            }
        }
        .onAppear { store.forgetReconnected(session) }
        .onChange(of: session.devices) { store.forgetReconnected(session) }
    }

    private func link(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(title, action: action)
                .buttonStyle(.link)
                .font(.caption)
                .lineLimit(1)
                .disabled(!session.pendingDevices.isEmpty)
                .help(help)
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.top, 4)
    }
}

// MARK: - Mode for calls

/// Picks the mode the pair switches to while the Mac is on a call; off until one is picked.
struct CallModeRow: View {
    let session: HeadphoneSession
    let calls: CallModeSwitch

    var body: some View {
        let options = session.noiseOptions
        if !options.isEmpty {
            let title = session.modeLayout != nil ? "Mode on calls" : "Noise cancelling on calls"
            ControlRow(title: title,
                       help: "Switch to this while an app uses this Mac's microphone and the headphones are in use, then switch back") {
                Picker(title, selection: Binding(
                    get: { calls.setting(for: session) }, set: { calls.set($0, for: session) })) {
                    Text("Don't change").tag(NoiseSetting?.none)
                    ForEach(choices(from: options)) { Text($0.name).tag(Optional($0.setting)) }
                }
            }
        }
    }

    /// The pair's options, plus the chosen one if its mode has since been deleted.
    private func choices(from options: [HeadphoneSession.NoiseOption]) -> [HeadphoneSession.NoiseOption] {
        guard let chosen = calls.setting(for: session), !options.contains(where: { $0.setting == chosen }) else {
            return options
        }
        return options + [.init(setting: chosen, name: "Deleted mode")]
    }
}
