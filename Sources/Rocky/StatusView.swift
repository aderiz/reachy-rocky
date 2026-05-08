import SwiftUI
import RobotLink
import SidecarHost
import Speech

/// Inspector → Health. Severity-first triage view.
///
/// Per `docs/concepts/cockpit-design.md` §1.9 + §3.4: rows are
/// reordered with the worst issue at the top; healthy items collapse
/// into a single "All other systems healthy" disclosure (default
/// closed when nothing's wrong). The colour state is carried by the
/// row's leading icon; the wallpaper "ok ok ok ok" pills are gone.
///
/// Inline actions ("Probe", "Authorize", "Disable") sit on the
/// trailing edge as compact bordered buttons. Inspector tabs render
/// inside a 12pt-padded ScrollView, so this view doesn't add an
/// outer header / page padding — the InspectorView already provides
/// the context.
struct StatusView: View {
    @Environment(AppServices.self) private var services
    @State private var healthyCollapsed: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow
            subsystemStrip
            issuesSection
            healthySection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Subsystem strip — visual hero

    /// Six tiles, one per Rocky subsystem. Tinted by status so the
    /// user sees "is Rocky whole?" at a glance — broken parts stand
    /// out without needing to read the rows below. Each tile is a
    /// button that scrolls the issues list to that subsystem.
    private var subsystemStrip: some View {
        let entries = allRows
        return HStack(spacing: 6) {
            ForEach(entries) { entry in
                SubsystemTile(entry: entry)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Health", systemImage: "heart.text.square")
                .font(.headline)
            Spacer()
            Text(summary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(summaryTint)
        }
    }

    private var summary: String {
        let issues = rowsByCategory.lazy.flatMap(\.1).filter { !$0.state.isHealthy }
        let issueCount = issues.count
        if issueCount == 0 { return "All clear" }
        return issueCount == 1 ? "1 issue" : "\(issueCount) issues"
    }

    private var summaryTint: Color {
        rowsByCategory.lazy.flatMap(\.1).contains { !$0.state.isHealthy }
            ? .orange : .green
    }

    // MARK: - Sections

    /// Rows that are not currently healthy, sorted worst-first. These
    /// appear at the top of the tab so the eye lands on the problem.
    @ViewBuilder
    private var issuesSection: some View {
        let issues = allRows
            .filter { !$0.state.isHealthy }
            .sorted { $0.state.severity > $1.state.severity }
        if issues.isEmpty {
            allClearCallout
        } else {
            VStack(spacing: 0) {
                ForEach(issues) { entry in
                    rowView(entry)
                    if entry.id != issues.last?.id {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// Healthy rows folded into a single disclosure. Open it when you
    /// want to see "yes the robot is online" reassurance, otherwise
    /// keep your eye on the issues above.
    @ViewBuilder
    private var healthySection: some View {
        let healthy = allRows.filter(\.state.isHealthy)
        if healthy.isEmpty {
            EmptyView()
        } else {
            DisclosureGroup(isExpanded: $healthyCollapsed.invertedBinding) {
                VStack(spacing: 0) {
                    ForEach(healthy) { entry in
                        rowView(entry)
                        if entry.id != healthy.last?.id {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("\(healthy.count) system\(healthy.count == 1 ? "" : "s") healthy")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var allClearCallout: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("All systems healthy. Rocky's body, brain, ears, voice, and memory are online.")
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Row view

    @ViewBuilder
    private func rowView(_ entry: HealthRow) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(entry.state.color.opacity(0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: entry.icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(entry.state.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.body.weight(.medium))
                Text(entry.subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            entry.action.map { action in
                Button(action.label) { action.run() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Row data model

    fileprivate struct HealthRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let state: HealthState
        let action: HealthAction?
    }

    fileprivate struct HealthAction {
        let label: String
        let run: () -> Void
    }

    fileprivate enum HealthState {
        case ok
        case warn
        case bad
        case unknown

        var isHealthy: Bool {
            switch self {
            case .ok: return true
            default:  return false
            }
        }

        var severity: Int {
            switch self {
            case .bad:     return 3
            case .warn:    return 2
            case .unknown: return 1
            case .ok:      return 0
            }
        }

        var color: Color {
            switch self {
            case .ok:      return .green
            case .warn:    return .orange
            case .bad:     return .red
            case .unknown: return .gray
            }
        }
    }

    // MARK: - Row computation

    fileprivate var rowsByCategory: [(String, [HealthRow])] {
        [
            ("Connections", [robotRow, llmRow]),
            ("Audio",       [micRow, sttRow]),
            ("Sidecars",    [faceSidecarRow, ttsSidecarRow, memorySidecarRow]),
        ]
    }

    fileprivate var allRows: [HealthRow] {
        rowsByCategory.flatMap(\.1)
    }

    private var robotRow: HealthRow {
        let state: HealthState
        let subtitle: String
        switch services.daemonReachability {
        case .online:
            state = .ok
            subtitle = "\(services.robotEndpoint.host):\(services.robotEndpoint.port)" +
                       " · \(services.stateUpdateCount) state frames"
        case .offline(let reason):
            state = .bad
            subtitle = reason
        case .unknown:
            state = .unknown
            subtitle = "checking…"
        }
        return HealthRow(
            id: "robot",
            title: "Robot daemon",
            subtitle: subtitle,
            icon: "antenna.radiowaves.left.and.right",
            state: state,
            action: HealthAction(label: "Probe") {
                Task { await services.probeRobotPublic() }
            }
        )
    }

    private var llmRow: HealthRow {
        let state: HealthState
        let subtitle: String
        switch services.llmStatus {
        case .online(let model):
            state = .ok
            subtitle = "model: \(model)"
        case .offline(let reason):
            state = .warn
            subtitle = reason
        case .unknown:
            state = .unknown
            subtitle = "checking…"
        }
        return HealthRow(
            id: "llm",
            title: "LM Studio",
            subtitle: subtitle,
            icon: "brain",
            state: state,
            action: HealthAction(label: "Probe") {
                Task { await services.probeLMStudioPublic() }
            }
        )
    }

    private var micRow: HealthRow {
        let state: HealthState = services.micEnabled ? .ok : .unknown
        let subtitle = services.micEnabled
            ? String(format: "live · RMS %.3f", services.lastMicRMS)
            : "not listening"
        return HealthRow(
            id: "mic",
            title: "Microphone",
            subtitle: subtitle,
            icon: services.micEnabled ? "mic.fill" : "mic.slash",
            state: state,
            action: HealthAction(label: services.micEnabled ? "Disable" : "Enable") {
                Task { await services.toggleMic() }
            }
        )
    }

    private var sttRow: HealthRow {
        let state: HealthState
        switch services.sttBackendName {
        case let n where n.contains("Apple Speech"): state = .ok
        case "unauthorized": state = .warn
        case "unavailable":  state = .bad
        default:             state = .unknown
        }
        return HealthRow(
            id: "stt",
            title: "Speech recognition",
            subtitle: services.sttBackendName,
            icon: "waveform.badge.mic",
            state: state,
            action: state == .warn
                ? HealthAction(label: "Authorize") {
                    Task { _ = await services.appleSTT.requestAuthorization() }
                }
                : nil
        )
    }

    /// The Mac-side face tracker (Vision framework) is the source of
    /// truth for `set_target` now — the deprecated Python sidecar
    /// reads as `.stopped` even when the bot is actively tracking
    /// the user, which read as a broken health row. Reflect the Mac
    /// tracker's live state instead: paused / tracking <name> /
    /// watching, with the same target+detection counters in the
    /// inspector via the Activity tab if the user wants the raw
    /// numbers.
    private var faceSidecarRow: HealthRow {
        let healthState: HealthState
        let subtitle: String
        if !services.faceTrackingEnabled {
            healthState = .unknown
            subtitle = "paused"
        } else if let last = services.lastFaceDetectionAt,
                  Date().timeIntervalSince(last) < 3 {
            healthState = .ok
            if let who = services.lastFaceDetection?.identity {
                subtitle = "tracking \(who)"
            } else {
                subtitle = "tracking"
            }
        } else {
            healthState = .ok
            subtitle = "watching"
        }
        return HealthRow(
            id: "facetracker",
            title: "Face tracker",
            subtitle: subtitle,
            icon: "eye",
            state: healthState,
            action: nil
        )
    }

    private var ttsSidecarRow: HealthRow {
        sidecarRow(
            id: "sidecar.tts",
            title: "TTS",
            icon: "speaker.wave.2",
            state: services.ttsSidecarState
        )
    }

    private var memorySidecarRow: HealthRow {
        let count = services.memoryDrawerCount
        let extra: String? = (count >= 0)
            ? (count == 1 ? "1 drawer" : "\(count) drawers")
            : nil
        return sidecarRow(
            id: "sidecar.memory",
            title: "Memory",
            icon: "tray.full",
            state: services.memorySidecarState,
            extra: extra
        )
    }

    private func sidecarRow(
        id: String,
        title: String,
        icon: String,
        state s: SidecarState,
        extra: String? = nil
    ) -> HealthRow {
        let healthState: HealthState
        let subtitle: String
        switch s {
        case .ready:
            healthState = .ok
            subtitle = ["ready", extra].compactMap { $0 }.joined(separator: " · ")
        case .starting:
            healthState = .warn
            subtitle = "starting…"
        case .stopped:
            healthState = .unknown
            subtitle = "stopped"
        case .failing(let reason):
            healthState = .bad
            subtitle = "failing · \(reason)"
        case .circuitOpen(let until):
            healthState = .bad
            let s = max(0, Int(until.timeIntervalSinceNow))
            subtitle = "cooldown · \(s)s"
        }
        return HealthRow(id: id, title: title, subtitle: subtitle,
                         icon: icon, state: healthState, action: nil)
    }
}

// MARK: - Subsystem tile

/// One of six subsystem icons in the Health tab's hero strip. Tinted
/// by status — broken systems pop, healthy ones recede. Click bounces
/// the row in the list (planned for a later cross-panel polish pass;
/// for now the click is a no-op anchor for the affordance).
private struct SubsystemTile: View {
    let entry: StatusView.HealthRow

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(entry.state.color.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: entry.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(entry.state.color)
            }
            Text(shortLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .help(entry.subtitle)
        .accessibilityLabel("\(entry.title): \(entry.subtitle)")
    }

    /// Five-char-or-less label so six tiles fit comfortably at the
    /// inspector's 320pt minimum width.
    private var shortLabel: String {
        switch entry.id {
        case "robot":          return "Body"
        case "llm":            return "Brain"
        case "mic":            return "Mic"
        case "stt":            return "Speech"
        case "facetracker":    return "Eyes"
        case "sidecar.tts":    return "Voice"
        case "sidecar.memory": return "Memory"
        default:               return entry.title
        }
    }
}

// MARK: - Helpers

private extension Binding where Value == Bool {
    /// Returns a binding that reads/writes the negation of the source.
    /// Used so a `DisclosureGroup(isExpanded:)` can drive a
    /// "collapsed" state variable without flipping signs at the
    /// callsite.
    var invertedBinding: Binding<Bool> {
        Binding<Bool>(
            get: { !self.wrappedValue },
            set: { self.wrappedValue = !$0 }
        )
    }
}
