import SwiftUI
import RobotLink
import SidecarHost
import Speech

/// Single-glance health panel. Lists every dependency Rocky needs and what's
/// wrong (if anything). Each row uses the unified Card chrome.
struct StatusView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                groupCard(title: "Connections") {
                    row(title: "Robot daemon",
                        subtitle: robotDetail,
                        state: robotState,
                        icon: "antenna.radiowaves.left.and.right") {
                        Button("Probe") {
                            Task { await services.probeRobotPublic() }
                        }
                        .controlSize(.small)
                    }
                    Divider().opacity(0.06)
                    row(title: "LM Studio",
                        subtitle: llmDetail,
                        state: llmState,
                        icon: "brain") {
                        Button("Probe") {
                            Task { await services.probeLMStudioPublic() }
                        }
                        .controlSize(.small)
                    }
                }

                groupCard(title: "Audio") {
                    row(title: "Microphone",
                        subtitle: micDetail,
                        state: micState,
                        icon: services.micEnabled ? "mic.fill" : "mic.slash") {
                        Button(services.micEnabled ? "Disable" : "Enable") {
                            Task { await services.toggleMic() }
                        }
                        .controlSize(.small)
                    }
                    Divider().opacity(0.06)
                    row(title: "Speech recognition",
                        subtitle: sttDetail,
                        state: sttState,
                        icon: "waveform.badge.mic") {
                        Button("Authorize") {
                            Task { _ = await services.appleSTT.requestAuthorization() }
                        }
                        .controlSize(.small)
                    }
                }

                groupCard(title: "Sidecars") {
                    row(title: "Face tracker",
                        subtitle: faceTrackerDetail,
                        state: sidecarState(services.faceTrackerSidecarState),
                        icon: "eye") { EmptyView() }
                    Divider().opacity(0.06)
                    row(title: "TTS",
                        subtitle: ttsDetail,
                        state: sidecarState(services.ttsSidecarState),
                        icon: "speaker.wave.2") { EmptyView() }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 980, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            HStack(spacing: 10) {
                Text(summaryText).foregroundStyle(.secondary)
                StatusPill(text: "\(healthyCount) / \(totalCount) healthy",
                           tint: healthyCount == totalCount ? .green : .orange,
                           systemImage: healthyCount == totalCount ? "checkmark.circle.fill" : "exclamationmark.circle")
            }
            .font(.subheadline)
        }
    }

    private var summaryText: String {
        if healthyCount == totalCount { return "Everything Rocky needs is online." }
        return "Some pieces need attention."
    }

    private var totalCount: Int { 6 }

    private var healthyCount: Int {
        var n = 0
        if robotState == .ok { n += 1 }
        if llmState == .ok { n += 1 }
        if micState == .ok { n += 1 }
        if sttState == .ok { n += 1 }
        if sidecarState(services.faceTrackerSidecarState) == .ok { n += 1 }
        if sidecarState(services.ttsSidecarState) == .ok { n += 1 }
        return n
    }

    // MARK: - Group card

    @ViewBuilder
    private func groupCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Card {
            CardHeader(title, icon: groupIcon(for: title))
        } content: {
            VStack(spacing: 0) { content() }
                .padding(.horizontal, -8)
                .padding(.vertical, -4)
        }
    }

    private func groupIcon(for title: String) -> String {
        switch title {
        case "Connections":  return "link"
        case "Audio":        return "ear"
        case "Sidecars":     return "shippingbox"
        default:             return "checkmark.shield"
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row<Trailing: View>(
        title: String,
        subtitle: String,
        state: RowState,
        icon: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(state.color.opacity(0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.body.weight(.semibold))
                    statePill(state: state)
                }
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func statePill(state: RowState) -> some View {
        switch state {
        case .ok:      StatusPill(text: "ok",        tint: .green,    systemImage: "checkmark")
        case .warn:    StatusPill(text: "warning",   tint: .orange,   systemImage: "exclamationmark")
        case .bad:     StatusPill(text: "down",      tint: .red,      systemImage: "xmark")
        case .unknown: StatusPill(text: "—",         tint: .secondary)
        }
    }

    // MARK: - Per-row state classification

    private enum RowState: Equatable {
        case ok, warn, bad, unknown
        var color: Color {
            switch self {
            case .ok:      .green
            case .warn:    .orange
            case .bad:     .red
            case .unknown: .gray
            }
        }
    }

    private var robotState: RowState {
        switch services.daemonReachability {
        case .online:  .ok
        case .offline: .bad
        case .unknown: .unknown
        }
    }
    private var robotDetail: String {
        switch services.daemonReachability {
        case .online:
            let endpoint = services.robotEndpoint
            return "\(endpoint.host):\(endpoint.port) · \(services.stateUpdateCount) state frames"
        case .offline(let reason): return reason
        case .unknown:             return "checking…"
        }
    }

    private var llmState: RowState {
        switch services.llmStatus {
        case .online:  .ok
        case .offline: .warn
        case .unknown: .unknown
        }
    }
    private var llmDetail: String {
        switch services.llmStatus {
        case .online(let model):  return "model: \(model)"
        case .offline(let reason): return reason
        case .unknown:             return "checking…"
        }
    }

    private var micState: RowState { services.micEnabled ? .ok : .unknown }
    private var micDetail: String {
        services.micEnabled
            ? String(format: "live · RMS %.3f", services.lastMicRMS)
            : "not listening"
    }

    private var sttState: RowState {
        switch services.sttBackendName {
        case let n where n.contains("Apple Speech"): .ok
        case "unauthorized": .warn
        case "unavailable":  .bad
        default:             .unknown
        }
    }
    private var sttDetail: String { services.sttBackendName }

    private func sidecarState(_ s: SidecarState) -> RowState {
        switch s {
        case .ready:        .ok
        case .starting:     .warn
        case .stopped:      .unknown
        case .failing:      .bad
        case .circuitOpen:  .bad
        }
    }

    private var faceTrackerDetail: String {
        let s = services.faceTrackerSidecarState
        let extra = "\(services.faceTargetCount) targets · \(services.faceDetectionCount) detections"
        switch s {
        case .stopped:                 return "stopped"
        case .starting:                return "starting…"
        case .ready:                   return "ready · " + extra
        case .failing(let reason):     return "failing · \(reason)"
        case .circuitOpen(let until):
            let s = max(0, Int(until.timeIntervalSinceNow))
            return "cooldown · \(s)s"
        }
    }

    private var ttsDetail: String {
        switch services.ttsSidecarState {
        case .stopped:                 return "stopped"
        case .starting:                return "starting…"
        case .ready:                   return "ready"
        case .failing(let reason):     return "failing · \(reason)"
        case .circuitOpen(let until):
            let s = max(0, Int(until.timeIntervalSinceNow))
            return "cooldown · \(s)s"
        }
    }
}
