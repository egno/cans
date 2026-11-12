import AppKit
import BMAP
import SwiftUI

// Popover pieces for the headphones' rarely used settings and their readouts: the gear
// menu's headphone items, renaming, what's playing and moving audio between two devices.
// `MenuView` only places them.

/// "5 h 20 min", "45 min".
func playTimeLabel(minutes: Int) -> String {
    let hours = minutes / 60, rest = minutes % 60
    if hours == 0 { return "\(rest) min" }
    return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
}

/// "Track 3 of 12", "Track 3", or nil when the source doesn't number its tracks.
func trackLabel(_ playing: NowPlaying) -> String? {
    guard let number = playing.trackNumber, number > 0 else { return nil }
    if let total = playing.totalTracks, total >= number { return "Track \(number) of \(total)" }
    return "Track \(number)"
}

// MARK: - Gear menu

/// The shown headphones' section of the gear menu: rename, voice prompts, pairing and
/// power. Things done once in a while, so they stay out of the popover itself.
struct HeadphoneMenuItems: View {
    let session: HeadphoneSession
    let rename: () -> Void

    var body: some View {
        let profile = session.profile
        let hasItems = profile.supports(.rename) || session.canChangeVoicePrompts
            || profile.supports(.pairingMode) || profile.supports(.powerOff)
        if hasItems {
            Section(session.displayName) {
                if profile.supports(.rename) {
                    Button("Rename…", action: rename)
                }
                if session.canChangeVoicePrompts, let prompts = session.voicePrompts {
                    voicePrompts(prompts)
                }
                if profile.supports(.pairingMode) {
                    Button("Pair a New Device") { session.enterPairingMode() }
                        .help("Put the headphones in Bluetooth pairing mode")
                }
                if profile.supports(.powerOff) {
                    Button("Turn Off") { session.powerOff() }
                        .disabled(session.isPoweringOff)
                        .help("Turn the headphones off; Cans finds them again when they're back on")
                }
            }
        }
    }

    private func voicePrompts(_ prompts: VoicePrompts) -> some View {
        Menu("Voice Prompts") {
            Toggle("Voice Prompts", isOn: Binding(
                get: { prompts.isOn }, set: { session.setVoicePrompts(isOn: $0) }))
            Picker("Language", selection: Binding(
                get: { prompts.language }, set: { session.setVoicePrompts(language: $0) })) {
                ForEach(Array(VoicePrompts.languageNames.enumerated()), id: \.offset) { index, name in
                    Text(name).tag(UInt8(index))
                }
                // A language this app has no name for stays selected rather than showing none.
                if prompts.languageName == nil {
                    Text("Language \(prompts.language)").tag(prompts.language)
                }
            }
            if let announce = prompts.batteryAnnouncement {
                Toggle("Say the Battery Level at Power On", isOn: Binding(
                    get: { announce }, set: { session.setVoicePrompts(batteryAnnouncement: $0) }))
            }
        }
    }
}

/// A new name for the headphones, typed in a row under the header.
struct RenameRow: View {
    let session: HeadphoneSession
    let done: () -> Void

    @State private var name = ""
    @State private var nameWasCut = false
    @State private var isSaving = false
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var canCommit: Bool { !trimmed.isEmpty && trimmed != session.displayName && !isSaving }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: name) { _, typed in
                        let fitted = NameLimit.fitting(typed, bytes: ProductName.maxBytes)
                        if fitted != typed {
                            name = fitted
                            nameWasCut = true
                        } else if typed.utf8.count < ProductName.maxBytes {
                            nameWasCut = false
                        }
                    }
                    .accessibilityLabel("New name for the headphones")
                if isSaving { ProgressView().controlSize(.small) }
                Button("Rename", action: commit).disabled(!canCommit)
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            Text(nameWasCut
                 ? "That's as long as the name can be."
                 : "Other devices show the new name once they reconnect.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Metrics.inset)
        .onAppear {
            name = session.displayName
            focused = true
        }
    }

    private func commit() {
        guard canCommit else { return }
        isSaving = true
        Task {
            // A refusal shows in the banner and leaves the row open.
            if await session.rename(to: trimmed) { done() }
            isSaving = false
        }
    }
}

// MARK: - Devices

/// The track the headphones are playing, when their source says. Nothing otherwise.
struct NowPlayingRow: View {
    let session: HeadphoneSession

    var body: some View {
        if session.profile.supports(.nowPlaying), let playing = session.nowPlaying, let title = playing.title {
            // Record 1 is taken to be the artist; it's shown as it comes, without a label.
            let caption = playing.text(1) ?? [trackLabel(playing),
                                              session.playingDevice.map { "from \(session.displayName(of: $0))" }]
                .compactMap { $0 }.joined(separator: " ")
            ListRow(symbol: "music.note", title: title, caption: caption.isEmpty ? nil : caption) { EmptyView() }
                .help(title)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Now playing, \(title)\(caption.isEmpty ? "" : ", \(caption)")")
        }
    }
}

/// With two devices connected, a link that moves playback to the one that isn't playing.
struct AudioRouteRow: View {
    let session: HeadphoneSession

    var body: some View {
        if let target = session.audioRouteTarget {
            let name = session.isThisMac(target) ? "This Mac" : target.name
            HStack {
                Spacer()
                Button("Switch Audio to \(name)") { session.routeAudio(to: target) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .lineLimit(1)
                    .disabled(!session.pendingDevices.isEmpty)
                    .help("Play from \(name) instead; both devices stay connected")
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.top, 4)
        }
    }
}
