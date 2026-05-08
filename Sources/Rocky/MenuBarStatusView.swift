import SwiftUI
import AppKit

/// Menu-bar popover — Rocky's *persistent* surface. Per
/// `docs/concepts/cockpit-design.md` §3.5, the menu bar is what Rocky
/// is, all day; the main window is what you open when you sit down to
/// work with him. ~80% of short interactions live in this popover —
/// glance the state, ask one thing, mute, pause, see the last exchange,
/// without ever opening the main window.
///
/// Layout, top to bottom:
///
///   - Presence row — Rocky thumbnail + name (`.headline`) + one
///     sentence of presence (the same line that lives under the cockpit
///     portrait).
///   - Recent moments (last 3) — placeholder rows until Wave 4 ships
///     the moment-feed actor; for now they crib the most recent brain
///     turns formatted as moment-style lines.
///   - Last exchange — the latest user / Rocky bubble pair so the user
///     can catch up at a glance.
///   - Ask Rocky — TextField + send. Goes through `sendUserText`. Reply
///     lands as a new "last exchange" without context-switching apps.
///   - Quick controls — wake/sleep · mute mic · mute voice · pause for X.
///   - Health affordance — one line; click opens the main window with
///     the inspector pinned to Health.
///   - Open Rocky — surfaces the main window. Future: `⌥⌘R` summons.
struct MenuBarStatusView: View {
    @Environment(AppServices.self) private var services
    @State private var ask: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            presenceRow
            Divider()
            recentMomentsBlock
            Divider()
            lastExchangeBlock
            Divider()
            askRow
            Divider()
            quickControlsRow
            Divider()
            healthLine
            Divider()
            openRockyRow
        }
        .frame(width: 360)
        .padding(.vertical, 6)
    }

    // MARK: - Presence

    private var presenceRow: some View {
        HStack(alignment: .center, spacing: 12) {
            MenuBarPresenceGlyph(rockyState: services.rockyState)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Rocky").font(.headline)
                Text(presenceLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var presenceLine: String {
        if services.isDoNotDisturb,
           let until = services.dndUntil {
            let mins = max(1, Int(until.timeIntervalSinceNow / 60))
            return "Quiet mode for \(mins) more minute\(mins == 1 ? "" : "s")."
        }
        switch services.rockyState {
        case .sleeping:    return "Asleep — say his name to wake."
        case .waking:      return "Waking up…"
        case .idle:        return "Awake, no one in view."
        case .tracking:
            if let name = services.lastFaceDetection?.identity {
                return "Watching \(name)."
            }
            return "Watching."
        case .listening:   return "Listening."
        case .thinking:    return "Thinking."
        case .speaking:    return "Speaking."
        case .error(let m): return m
        }
    }

    // MARK: - Recent moments

    private var recentMomentsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Recent")
            // Real moments from MomentFeed — last 3 in reverse-chrono.
            // The Inspector / Activity tab shows the full list with
            // filters and source detail.
            let recent = Array(services.recentMoments.suffix(3).reversed())
            if recent.isEmpty {
                Text("All quiet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            } else {
                ForEach(recent) { moment in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: moment.symbolName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .center)
                        Text(moment.sentence)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Last exchange

    private var lastExchangeBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Last exchange")
            let lastUser = services.brainTurns.last(where: { $0.role == "user" })
            let lastAssistant = services.brainTurns.last(where: { $0.role == "assistant" })
            if lastUser == nil && lastAssistant == nil {
                Text("No exchanges yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            } else {
                if let u = lastUser {
                    Text("You: \(u.content)")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .lineLimit(2)
                }
                if let r = lastAssistant {
                    Text("Rocky: \(r.content)")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .lineLimit(3)
                }
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Ask

    private var askRow: some View {
        HStack(spacing: 8) {
            TextField("Ask Rocky…", text: $ask)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitAsk() }
            Button {
                submitAsk()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(ask.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Quick controls

    private var quickControlsRow: some View {
        HStack(spacing: 8) {
            quickButton(
                label: services.isAsleep ? "Wake" : "Sleep",
                icon: services.isAsleep ? "sun.max.fill" : "moon.fill"
            ) {
                Task {
                    if services.isAsleep { await services.wakeRobot() }
                    else { await services.sleepRobot() }
                }
            }
            quickButton(
                label: services.micEnabled ? "Mute" : "Listen",
                icon: services.micEnabled ? "mic.slash" : "mic.fill"
            ) {
                Task { await services.toggleMic() }
            }
            quickButton(
                label: services.ttsMuted ? "Voice on" : "Voice off",
                icon: services.ttsMuted ? "speaker.slash" : "speaker.wave.2.fill"
            ) {
                Task { await services.toggleTTSMute() }
            }
            pauseMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// "Pause for X" with a menu of canned durations. Active dnd shows
    /// remaining minutes inline.
    private var pauseMenu: some View {
        @Bindable var bindable = services
        return Menu {
            if services.isDoNotDisturb {
                Button("Resume now", role: .destructive) {
                    services.pauseFor(minutes: nil)
                }
                Divider()
            }
            Button("15 minutes")  { services.pauseFor(minutes: 15) }
            Button("30 minutes")  { services.pauseFor(minutes: 30) }
            Button("1 hour")      { services.pauseFor(minutes: 60) }
            Button("Until I quit") {
                services.pauseFor(minutes: 60 * 24)  // 24h cap; clearing on quit handled elsewhere
            }
        } label: {
            if services.isDoNotDisturb,
               let until = services.dndUntil {
                let mins = max(1, Int(until.timeIntervalSinceNow / 60))
                Label("\(mins)m", systemImage: "pause.circle.fill")
            } else {
                Label("Pause", systemImage: "pause.circle")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func quickButton(
        label: String, icon: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .labelStyle(.iconOnly)
                .font(.body)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .help(label)
    }

    // MARK: - Health line

    private var healthLine: some View {
        let glance = services.healthGlance
        return HStack(spacing: 8) {
            Image(systemName: glance.symbol)
                .foregroundStyle(glance.tint)
                .frame(width: 16)
            Text(glance.tooltip ?? "All clear.")
                .font(.callout)
                .foregroundStyle(glance.tooltip == nil ? .secondary : .primary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Open Rocky

    private var openRockyRow: some View {
        HStack {
            Button {
                openMainWindow()
            } label: {
                Label("Open Rocky", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    private func submitAsk() {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ask = ""
        Task { await services.sendUserText(text) }
    }

    private func openMainWindow() {
        // Ensure the app is foregrounded — MenuBarExtra doesn't activate
        // the app on its own. We then bring the existing main window to
        // the front, or open a new one if all of them have been closed.
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Rocky" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // No window currently — try the standard "show window" action
            // which works for a `WindowGroup`.
            if let action = NSApp.windows
                .flatMap({ $0.standardWindowButton(.zoomButton)?.target as? NSObject == nil ? [$0] : [] })
                .first {
                action.makeKeyAndOrderFront(nil)
            }
        }
    }
}

/// Animated SF Symbol that conveys Rocky's state at a glance. Lives in
/// the popover's presence row at 36pt and as the menu-bar label icon
/// (via `MenuBarLabel`) at the standard menu-bar size.
struct MenuBarPresenceGlyph: View {
    let rockyState: AppServices.RockyState

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.15))
            Image(systemName: symbolName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating, isActive: isPulsing)
                .symbolEffect(.variableColor, options: .repeating, isActive: isThinking)
        }
        .accessibilityLabel(accessibleStateLabel)
    }

    /// Active pulse for "alive and listening / speaking" states. Reduce
    /// Motion respected: SwiftUI suppresses indefinite symbol effects
    /// automatically.
    private var isPulsing: Bool {
        switch rockyState {
        case .listening, .speaking: return true
        default: return false
        }
    }

    private var isThinking: Bool {
        if case .thinking = rockyState { return true }
        return false
    }

    private var symbolName: String {
        switch rockyState {
        case .sleeping:    return "moon.zzz.fill"
        case .waking:      return "sun.max.fill"
        case .idle:        return "circle.dotted"
        case .tracking:    return "eye.fill"
        case .listening:   return "ear.fill"
        case .thinking:    return "brain"
        case .speaking:    return "waveform"
        case .error:       return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch rockyState {
        case .sleeping:    return .secondary
        case .waking:      return .orange
        case .idle:        return .secondary
        case .tracking:    return .accentColor
        case .listening:   return .green
        case .thinking:    return .blue
        case .speaking:    return .orange
        case .error:       return .red
        }
    }

    private var accessibleStateLabel: String {
        switch rockyState {
        case .sleeping:    return "Rocky is asleep."
        case .waking:      return "Rocky is waking up."
        case .idle:        return "Rocky is idle."
        case .tracking:    return "Rocky is watching."
        case .listening:   return "Rocky is listening."
        case .thinking:    return "Rocky is thinking."
        case .speaking:    return "Rocky is speaking."
        case .error(let m): return "Rocky has an error: \(m)"
        }
    }
}
