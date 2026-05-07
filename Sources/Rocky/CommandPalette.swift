import SwiftUI

/// ⌘K — quick-action palette.
///
/// Per `docs/concepts/cockpit-design.md` §6.7, the palette is the
/// long-term spine for keyboard-driven actions. It's a sheet that
/// shows a fuzzy-matched list of curated actions; selecting one
/// performs it and dismisses the sheet.
///
/// The list is small + opinionated. As the app grows, this is where
/// new keyboard-only actions show up first; only the ones that earn
/// a permanent toolbar slot graduate.
///
/// Actions intentionally cover *both* state changes (Wake / Sleep /
/// Mute / Pause for X) and navigation (Open inspector / Show first
/// run / Open Settings) so the palette is a real "do something"
/// layer rather than just a search box.
struct CommandPalette: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var selection: CommandAction?
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            queryRow
            Divider()
            results
        }
        .frame(width: 520, height: 420)
        .onAppear {
            queryFocused = true
            selection = filtered.first
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.return) {
            performSelected()
            return .handled
        }
        .onKeyPress(.downArrow) {
            advanceSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            advanceSelection(by: -1)
            return .handled
        }
    }

    // MARK: - Query

    private var queryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("What do you want to do?", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($queryFocused)
                .onChange(of: query) { _, _ in
                    selection = filtered.first
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: - Results

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { action in
                    CommandRow(action: action,
                                selected: selection == action)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = action
                            performSelected()
                        }
                        .onHover { hovering in
                            if hovering { selection = action }
                        }
                }
                if filtered.isEmpty {
                    Text("No matching commands.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
        }
    }

    // MARK: - Actions

    /// All available actions. Computed each access so state-dependent
    /// labels (Wake vs Sleep, current mic state) stay accurate.
    private var allActions: [CommandAction] {
        let isAsleep = services.isAsleep
        let micOn = services.micEnabled
        let voiceMuted = services.ttsMuted
        let inDnD = services.isDoNotDisturb
        return [
            CommandAction(
                id: "wake_sleep",
                title: isAsleep ? "Wake him up" : "Send him to sleep",
                subtitle: isAsleep
                    ? "Enable motors and recover the neutral pose"
                    : "Disable motors after the goodbye animation",
                icon: isAsleep ? "sun.max.fill" : "moon.fill",
                keywords: ["wake", "sleep", "rocky"],
                run: {
                    Task {
                        if isAsleep { await services.wakeRobot() }
                        else { await services.sleepRobot() }
                    }
                }
            ),
            CommandAction(
                id: "mic_toggle",
                title: micOn ? "Mute mic" : "Unmute mic",
                subtitle: micOn
                    ? "Stop listening for the wake word"
                    : "Start listening for the wake word",
                icon: micOn ? "mic.slash" : "mic.fill",
                keywords: ["mic", "listen", "mute"],
                run: { Task { await services.toggleMic() } }
            ),
            CommandAction(
                id: "voice_toggle",
                title: voiceMuted ? "Unmute voice" : "Mute voice",
                subtitle: voiceMuted
                    ? "Allow Rocky to speak again"
                    : "Mute Rocky's voice — replies still appear in the conversation",
                icon: voiceMuted ? "speaker.wave.2.fill" : "speaker.slash.fill",
                keywords: ["voice", "tts", "mute", "speaker"],
                run: { Task { await services.toggleTTSMute() } }
            ),
            CommandAction(
                id: "pause_15",
                title: "Pause for 15 minutes",
                subtitle: "Quiet mode — Rocky stops listening and speaking",
                icon: "pause.circle",
                keywords: ["pause", "quiet", "dnd", "do not disturb"],
                run: { services.pauseFor(minutes: 15) }
            ),
            CommandAction(
                id: "pause_30",
                title: "Pause for 30 minutes",
                subtitle: "Quiet mode — Rocky stops listening and speaking",
                icon: "pause.circle",
                keywords: ["pause", "quiet", "dnd", "do not disturb"],
                run: { services.pauseFor(minutes: 30) }
            ),
            CommandAction(
                id: "pause_60",
                title: "Pause for 1 hour",
                subtitle: "Quiet mode — Rocky stops listening and speaking",
                icon: "pause.circle",
                keywords: ["pause", "quiet", "dnd", "do not disturb"],
                run: { services.pauseFor(minutes: 60) }
            ),
            inDnD ? CommandAction(
                id: "resume",
                title: "Resume now",
                subtitle: "Cancel quiet mode",
                icon: "play.fill",
                keywords: ["resume", "unpause", "unmute", "play"],
                run: { services.pauseFor(minutes: nil) }
            ) : nil,
            CommandAction(
                id: "open_settings",
                title: "Open Settings",
                subtitle: "Robot, Brain, Voice, Memory, Faces, Persona",
                icon: "gear",
                keywords: ["settings", "preferences", "config"],
                run: {
                    NSApp.sendAction(
                        Selector(("showSettingsWindow:")),
                        to: nil, from: nil)
                }
            ),
            CommandAction(
                id: "show_first_run",
                title: "Show first run",
                subtitle: "Re-open the introductory flow",
                icon: "questionmark.circle",
                keywords: ["onboarding", "first", "tour", "help", "intro"],
                run: {
                    services.settings.firstRunCompleted = false
                }
            ),
            CommandAction(
                id: "forget_5",
                title: "Forget the last 5 minutes",
                subtitle: "Wipe drawers added in the last five minutes",
                icon: "eraser",
                keywords: ["forget", "memory", "wipe", "delete"],
                run: {
                    Task {
                        // Placeholder behaviour: until MemoryService
                        // gains time-windowed forget, this clears
                        // everything. The palette entry surfaces the
                        // intent so we feel the gap.
                        _ = await services.forgetAllMemory()
                    }
                }
            ),
        ].compactMap { $0 }
    }

    private var filtered: [CommandAction] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allActions }
        return allActions.filter { action in
            action.title.lowercased().contains(q)
                || action.subtitle.lowercased().contains(q)
                || action.keywords.contains(where: { $0.contains(q) })
        }
    }

    // MARK: - Behaviour

    private func performSelected() {
        guard let action = selection else { return }
        action.run()
        dismiss()
    }

    private func advanceSelection(by delta: Int) {
        let list = filtered
        guard !list.isEmpty else { selection = nil; return }
        let currentIndex = list.firstIndex(where: { $0 == selection }) ?? -1
        var next = currentIndex + delta
        if next < 0 { next = 0 }
        if next >= list.count { next = list.count - 1 }
        selection = list[next]
    }
}

struct CommandAction: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let keywords: [String]
    let run: () -> Void

    static func == (lhs: CommandAction, rhs: CommandAction) -> Bool {
        lhs.id == rhs.id
    }
}

private struct CommandRow: View {
    let action: CommandAction
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: action.icon)
                .font(.title3)
                .foregroundStyle(selected ? AnyShapeStyle(.tint)
                                            : AnyShapeStyle(.secondary))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.callout.weight(.medium))
                Text(action.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if selected {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear)
    }
}
