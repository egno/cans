import BMAP
import SwiftUI

// Popover pieces for the mode table: immersive audio, the custom mode editor, favourites
// and "remember my mode". `ModesSection` in `MenuView` only places them.

/// What the form under the mode list is doing.
enum ModeEditing: Equatable {
    /// `original` is nil for a new mode in an unused slot.
    case edit(ModeEdit, original: ModeConfig?)
    case delete(ModeConfig)
}

/// Text cut to what a name field on the headphones holds.
enum NameLimit {
    /// The longest beginning of `text` that fits `bytes` of UTF-8 without splitting a character.
    static func fitting(_ text: String, bytes: Int) -> String {
        var out = "", used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= bytes else { break }
            out.append(character)
            used += size
        }
        return out
    }
}

/// How strongly a custom mode cancels noise, the way the popover says it. The headphones
/// count the other way: their 0 is full cancelling and 10 full awareness.
enum NoiseCancelling {
    static let range = 0...Int(ModeEdit.cncLevels.upperBound)

    /// 0 (aware) to 10 (full) from the headphones' level.
    static func strength(cncLevel: UInt8) -> Int {
        range.upperBound - min(Int(cncLevel), range.upperBound)
    }

    static func cncLevel(strength: Int) -> UInt8 {
        UInt8(range.upperBound - max(range.lowerBound, min(range.upperBound, strength)))
    }

    /// "Full", "Aware", or "7 of 10".
    static func label(strength: Int) -> String {
        switch strength {
        case range.upperBound...: "Full"
        case ...range.lowerBound: "Aware"
        default: "\(strength) of \(range.upperBound)"
        }
    }
}

/// Why a mode can't be saved under this name; nil when it can. `index` is the slot being
/// written, whose own name doesn't count as taken.
@MainActor
func modeNameProblem(_ name: String, index: UInt8, in session: HeadphoneSession) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return "Give the mode a name" }
    // The firmware's own word for an unused slot.
    if trimmed.lowercased() == "none" { return "The headphones use “None” for unused modes" }
    if session.modes.contains(where: { $0.index != index && $0.name.lowercased() == trimmed.lowercased() }) {
        return "There's already a mode with this name"
    }
    return nil
}

/// Edit and delete for one of the user's modes, behind an ellipsis on its row.
struct ModeRowMenu: View {
    let session: HeadphoneSession
    let config: ModeConfig
    @Binding var editing: ModeEditing?

    var body: some View {
        Menu {
            Button("Edit…") { editing = .edit(ModeEdit(editing: config), original: config) }
            if session.profile.supports(.favorites), session.favorites != nil {
                Toggle("Favourite", isOn: Binding(
                    get: { session.isFavorite(config.index) }, set: { session.setFavorite(config.index, $0) }))
            }
            Divider()
            Button("Delete…", role: .destructive) { editing = .delete(config) }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Edit or delete \(config.name)")
        .accessibilityLabel("\(config.name) options")
    }
}

/// Under the mode list: the form for a mode being edited, immersive audio, and a menu for
/// the things about modes that are set once.
struct ModeExtras: View {
    let session: HeadphoneSession
    @Binding var editing: ModeEditing?

    var body: some View {
        switch editing {
        case .edit(let edit, let original):
            ModeEditor(session: session, edit: edit, original: original) { editing = nil }
                // A fresh form per slot.
                .id(edit.index)
        case .delete(let config):
            ModeDeleteConfirmation(session: session, config: config) { editing = nil }
        case nil:
            EmptyView()
        }
        if session.profile.supports(.immersiveAudio), let mode = session.immersiveAudio {
            HStack {
                Text("Immersive audio")
                Spacer(minLength: 8)
                ImmersivePicker(selection: Binding(get: { mode }, set: { session.setImmersiveAudio($0) }))
            }
            .font(.caption)
            .padding(.horizontal, Metrics.inset)
            .help("Spatial sound: Still keeps it in place when you turn your head, Motion moves it with you")
        }
        if hasOptions {
            HStack {
                Spacer()
                ModeOptionsMenu(session: session, editing: $editing)
            }
            .padding(.horizontal, Metrics.inset)
        }
    }

    private var hasOptions: Bool {
        let profile = session.profile
        return profile.supports(.customModes) && !session.modeConfigs.isEmpty
            || profile.supports(.favorites) && session.favorites != nil
            || profile.supports(.rememberMode) && session.rememberMode != nil
    }
}

/// Off, Still, Motion as a segmented control.
private struct ImmersivePicker: View {
    @Binding var selection: ImmersiveAudio

    var body: some View {
        Picker("Immersive audio", selection: $selection) {
            ForEach(ImmersiveAudio.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}

/// New mode, which modes the headphones' button cycles through, and the mode at power on.
private struct ModeOptionsMenu: View {
    let session: HeadphoneSession
    @Binding var editing: ModeEditing?

    var body: some View {
        let profile = session.profile
        Menu {
            if profile.supports(.customModes), !session.modeConfigs.isEmpty {
                Button("New Mode…") {
                    if let slot = session.emptyModeSlot {
                        editing = .edit(ModeEdit(index: slot.index, name: ""), original: nil)
                    }
                }
                .disabled(session.emptyModeSlot == nil)
                .help(ifAny: session.emptyModeSlot == nil ? "Every custom mode is in use; delete one first" : nil)
            }
            if profile.supports(.favorites), session.favorites != nil {
                Section("Button Cycles Through") {
                    ForEach(session.modes) { mode in
                        Toggle(mode.name, isOn: Binding(
                            get: { session.isFavorite(mode.index) }, set: { session.setFavorite(mode.index, $0) }))
                    }
                }
            }
            if profile.supports(.rememberMode), let remember = session.rememberMode {
                Section {
                    Toggle("Turn On in the Last Mode Used", isOn: Binding(
                        get: { remember }, set: { session.setRememberMode($0) }))
                }
            }
        } label: {
            Text("Mode Options").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a mode, choose the modes the headphones' button cycles through, and the mode they turn on in")
    }
}

/// Name and settings of one custom mode. Opens in the popover itself: a menu bar popover
/// closes under a sheet or an alert.
private struct ModeEditor: View {
    let session: HeadphoneSession
    /// Nil for a new mode.
    let original: ModeConfig?
    let done: () -> Void

    @State private var draft: ModeEdit
    /// The typed name was longer than the headphones keep.
    @State private var nameWasCut = false
    @State private var isSaving = false
    @FocusState private var nameFocused: Bool

    init(session: HeadphoneSession, edit: ModeEdit, original: ModeConfig?, done: @escaping () -> Void) {
        self.session = session
        self.original = original
        self.done = done
        _draft = State(initialValue: edit)
    }

    /// The slot's record, which says what may be changed; an unused slot has one too.
    private var slot: ModeConfig? { original ?? session.modeConfig(at: draft.index) }

    private func canChange(_ setting: ModeConfig.Mutability) -> Bool {
        slot?.mutability.contains(setting) ?? true
    }

    private var problem: String? { modeNameProblem(draft.name, index: draft.index, in: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(original.map { "Edit \($0.name)" } ?? "New Mode")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Mode name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($nameFocused)
                .onSubmit(save)
                .onChange(of: draft.name) { _, typed in
                    let fitted = NameLimit.fitting(typed, bytes: ModeEdit.maxNameBytes)
                    if fitted != typed {
                        draft.name = fitted
                        nameWasCut = true
                    } else if typed.utf8.count < ModeEdit.maxNameBytes {
                        nameWasCut = false
                    }
                }
                .accessibilityLabel("Mode name")
            if nameWasCut {
                Text("That's as long as a mode's name can be.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if canChange(.cncLevel) || canChange(.windBlock) { noiseRows }
            if slot?.spatial != nil, canChange(.spatial) {
                HStack {
                    Text("Immersive audio")
                    Spacer(minLength: 8)
                    ImmersivePicker(selection: $draft.spatial)
                }
                .font(.caption)
            }
            HStack(spacing: 8) {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(original == nil ? "Create" : "Save", action: save)
                    .disabled(problem != nil || isSaving)
                    .help(ifAny: draft.name.isEmpty ? nil : problem)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Metrics.tileRadius).fill(.quinary))
        .onAppear { nameFocused = true }
    }

    /// The strength slider, which wind block takes over: it only works at full cancelling.
    @ViewBuilder private var noiseRows: some View {
        let strength = draft.windBlock ? NoiseCancelling.range.upperBound : NoiseCancelling.strength(cncLevel: draft.cncLevel)
        if canChange(.cncLevel) {
            HStack(spacing: 8) {
                Text("Noise cancelling")
                Slider(value: Binding(
                    get: { Double(strength) },
                    set: { draft.cncLevel = NoiseCancelling.cncLevel(strength: Int($0.rounded())) }),
                       in: Double(NoiseCancelling.range.lowerBound)...Double(NoiseCancelling.range.upperBound), step: 1)
                    .controlSize(.small)
                    .disabled(draft.windBlock)
                    .accessibilityLabel("Noise cancelling")
                    .accessibilityValue(NoiseCancelling.label(strength: strength))
                Text(NoiseCancelling.label(strength: strength))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            .font(.caption)
            .help(draft.windBlock
                  ? "Wind block always uses full noise cancelling"
                  : "From hearing your surroundings (Aware) to blocking the most noise (Full)")
        }
        if slot?.windBlock != nil, canChange(.windBlock) {
            ControlRow(title: "Wind block", help: "Cuts wind rumble; always uses full noise cancelling") {
                Toggle("Wind block", isOn: $draft.windBlock)
            }
        }
    }

    private func save() {
        guard problem == nil, !isSaving else { return }
        var edit = draft
        edit.name = draft.name.trimmingCharacters(in: .whitespaces)
        isSaving = true
        Task {
            // A refusal shows in the banner and leaves the form open to try again.
            if await session.saveMode(edit) { done() }
            isSaving = false
        }
    }
}

/// Asks before a custom mode is deleted: the headphones keep no copy.
private struct ModeDeleteConfirmation: View {
    let session: HeadphoneSession
    let config: ModeConfig
    let done: () -> Void
    @State private var isDeleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Delete \(config.name)? The headphones forget the mode, and it can't be brought back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if isDeleting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Delete Mode", role: .destructive) {
                    isDeleting = true
                    Task {
                        _ = await session.deleteMode(config.index)
                        done()
                    }
                }
                .disabled(isDeleting)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Metrics.tileRadius).fill(.quinary))
    }
}
