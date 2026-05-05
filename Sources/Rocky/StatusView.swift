import SwiftUI
import RobotLink
import SidecarHost
import Speech

/// Single-glance health panel. Lists every dependency Rocky needs and what's
/// wrong (if anything). Doubles as the "onboarding checklist" — each row has
/// an action that re-runs its check or kicks off recovery.
struct StatusView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Status")
                    .font(.title2.weight(.semibold))
                Text("Everything Rocky depends on, in one place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                rows
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var rows: some View {
        VStack(spacing: 8) {
            row(
                title: "Robot daemon",
                detail: robotDetail,
                state: robotState
            ) {
                Button("Probe") { Task { await services.probeRobotPublic() } }
            }
            row(
                title: "LM Studio",
                detail: llmDetail,
                state: llmState
            ) {
                Button("Probe") { Task { await services.probeLMStudioPublic() } }
            }
            row(
                title: "Microphone",
                detail: micDetail,
                state: micState
            ) {
                if !services.micEnabled {
                    Button("Enable") { Task { await services.toggleMic() } }
                } else {
                    Button("Disable") { Task { await services.toggleMic() } }
                }
            }
            row(
                title: "Speech recognition",
                detail: sttDetail,
                state: sttState
            ) {
                Button("Authorize") {
                    Task {
                        _ = await services.appleSTT.requestAuthorization()
                    }
                }
            }
            row(
                title: "Face tracker (sidecar)",
                detail: faceTrackerDetail,
                state: sidecarState(services.faceTrackerSidecarState)
            ) {
                EmptyView()
            }
            row(
                title: "TTS (sidecar)",
                detail: ttsDetail,
                state: sidecarState(services.ttsSidecarState)
            ) {
                EmptyView()
            }
        }
    }

    // MARK: - Per-row state classification

    private enum RowState {
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
            let frames = services.stateUpdateCount
            return "\(endpoint.host):\(endpoint.port) · \(frames) frames"
        case .offline(let reason):
            return reason
        case .unknown:
            return "checking…"
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
        case .online(let model): return "model: \(model)"
        case .offline(let reason): return reason
        case .unknown:           return "checking…"
        }
    }

    private var micState: RowState {
        services.micEnabled ? .ok : .unknown
    }

    private var micDetail: String {
        if services.micEnabled {
            return String(format: "live · RMS %.3f", services.lastMicRMS)
        }
        return "not listening"
    }

    private var sttState: RowState {
        switch services.sttBackendName {
        case "Apple Speech": .ok
        case "unauthorized": .warn
        case "unavailable":  .bad
        default:             .unknown
        }
    }

    private var sttDetail: String {
        services.sttBackendName
    }

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
        let extra = "\(services.faceTargetCount) targets, \(services.faceDetectionCount) detections"
        switch s {
        case .stopped:                 return "stopped · " + extra
        case .starting:                return "starting…"
        case .ready:                   return "ready · " + extra
        case .failing(let reason):     return "failing · \(reason)"
        case .circuitOpen(let until):
            let s = max(0, Int(until.timeIntervalSinceNow))
            return "circuit open · \(s)s cooldown"
        }
    }

    private var ttsDetail: String {
        switch services.ttsSidecarState {
        case .stopped:    return "stopped"
        case .starting:   return "starting…"
        case .ready:      return "ready"
        case .failing(let reason): return "failing · \(reason)"
        case .circuitOpen(let until):
            let s = max(0, Int(until.timeIntervalSinceNow))
            return "circuit open · \(s)s cooldown"
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func row(
        title: String,
        detail: String,
        state: RowState,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(state.color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            action()
                .controlSize(.small)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
