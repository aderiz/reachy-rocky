import SwiftUI

/// PortraitView — the stage's left column.
///
/// Per `docs/concepts/cockpit-design.md` §3.1, the portrait is the
/// visual centre of the app. The 3D head fills the column; underneath,
/// Rocky's name (`.title.weight(.semibold)`), a single sentence of
/// presence (`.callout`, secondary), and *one* primary action that
/// follows state.
///
/// State is read by anatomy, not by badges:
///   - eyes track when watching, blink when idle, slump in sleep,
///   - antennas tip on tracking, droop in sleep,
///   - the head pitches forward when speaking,
///
/// All driven by `services.lastRobotState` through the existing
/// `ReachyHead3D` view. We deliberately don't surface latency pills,
/// botMode badges, or tool-call counters here — those live in the
/// inspector. This column is for *reading Rocky as a being*.
struct PortraitView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            head
                .padding(.horizontal, 24)
            Spacer(minLength: 0)
            namePlate
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            primaryAction
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: - Head

    private var head: some View {
        ReachyMiniAvatar(
            state: services.rockyState,
            pose: services.lastRobotState?.headPose,
            antennas: services.lastRobotState?.antennasPosition,
            bodyYaw: services.lastRobotState?.bodyYaw,
            headJoints: services.lastRobotState?.headJoints,
            passiveJoints: services.lastRobotState?.passiveJoints
        )
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 520, maxHeight: 520)
        .accessibilityElement()
        .accessibilityLabel(accessibilityState)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Name plate (the only typography on the stage)

    private var namePlate: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rocky")
                .font(.title.weight(.semibold))
            Text(presenceLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Single sentence describing what Rocky is doing right now. The
    /// same string lives in the menu-bar popover (so the two surfaces
    /// don't drift), but is computed here from `rockyState` directly so
    /// the views stay independently testable.
    private var presenceLine: String {
        if services.isDoNotDisturb,
           let until = services.dndUntil {
            let mins = max(1, Int(until.timeIntervalSinceNow / 60))
            return "Quiet mode for \(mins) more minute\(mins == 1 ? "" : "s")."
        }
        switch services.rockyState {
        case .sleeping:    return "Asleep — say his name to wake."
        case .waking:      return "Waking up…"
        case .idle:        return "Awake. No one's in front of him yet."
        case .tracking:
            if let name = services.lastFaceDetection?.identity {
                return "Watching \(name)."
            }
            return "Watching."
        case .listening:
            if let name = services.lastFaceDetection?.identity {
                return "Listening to \(name)."
            }
            return "Listening."
        case .thinking:    return "Thinking."
        case .speaking:    return "Speaking."
        case .error(let m): return m
        }
    }

    private var accessibilityState: String {
        "Rocky's head, animated. \(presenceLine)"
    }

    // MARK: - Primary action — one button, follows state

    /// Per the design doc: one primary action whose meaning follows the
    /// state. Wake when asleep, Sleep when awake; "Stop talking" wins
    /// while a TTS clip is playing because that's the most-likely thing
    /// you want to interrupt.
    @ViewBuilder
    private var primaryAction: some View {
        let primary = primaryActionDescriptor
        Button(action: primary.action) {
            HStack(spacing: 6) {
                Image(systemName: primary.icon)
                Text(primary.label)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(primary.tint)
        .keyboardShortcut(primary.shortcut.0, modifiers: primary.shortcut.1)
        .disabled(primary.disabled)
        .help(primary.tooltip)
    }

    private struct PrimaryAction {
        let label: String
        let icon: String
        let tint: Color
        let action: () -> Void
        let shortcut: (KeyEquivalent, EventModifiers)
        let disabled: Bool
        let tooltip: String
    }

    private var primaryActionDescriptor: PrimaryAction {
        // Mute-while-speaking takes precedence — that's the most-likely
        // thing you reach for the button to do mid-turn. (Real
        // mid-clip cancel needs daemon-side support; muting is the
        // user-visible equivalent for now.)
        if let busyUntil = services.ttsBusyUntil, Date() < busyUntil,
           !services.ttsMuted {
            return .init(
                label: "Stop talking",
                icon: "speaker.slash.fill",
                tint: .orange,
                action: { Task { await services.toggleTTSMute() } },
                shortcut: (".", [.command]),
                disabled: false,
                tooltip: "Mute Rocky's voice. ⌘."
            )
        }
        switch services.rockyState {
        case .sleeping, .error:
            return .init(
                label: "Wake him up",
                icon: "sun.max.fill",
                tint: .accentColor,
                action: { Task { await services.wakeRobot() } },
                shortcut: (.return, []),
                disabled: false,
                tooltip: "Enable motors and recover the neutral pose. ⏎"
            )
        case .waking:
            return .init(
                label: "Waking…",
                icon: "hourglass",
                tint: .secondary,
                action: {},
                shortcut: (.return, []),
                disabled: true,
                tooltip: "Rocky is currently waking up."
            )
        case .idle, .tracking, .listening, .thinking, .speaking:
            return .init(
                label: "Send him to sleep",
                icon: "moon.fill",
                tint: .indigo,
                action: { Task { await services.sleepRobot() } },
                shortcut: (.return, [.shift]),
                disabled: false,
                tooltip: "Disable motors after the goodbye animation. ⇧⏎"
            )
        }
    }
}
