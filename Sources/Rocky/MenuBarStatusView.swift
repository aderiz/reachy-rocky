import SwiftUI

/// Menu bar surface. Custom icon + status mirror Rocky's `RockyState`;
/// the popup reveals quick actions: mute mic / mute voice / pause
/// face-tracking / wake / sleep / open dashboard / quit.
struct MenuBarStatusView: View {
    @Environment(AppServices.self) private var services
    @State private var faceTrackingPaused: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                StateBadge(state: services.rockyState).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Rocky").font(.headline)
                    Text(stateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)

            Divider()

            VStack(spacing: 0) {
                row(label: services.micEnabled ? "Mute mic" : "Listen",
                    systemImage: services.micEnabled ? "mic.slash" : "mic") {
                    Task { await services.toggleMic() }
                }
                row(label: services.ttsMuted ? "Unmute voice" : "Mute voice",
                    systemImage: services.ttsMuted ? "speaker.slash" : "speaker.wave.2") {
                    Task { await services.toggleTTSMute() }
                }
                row(label: faceTrackingPaused ? "Resume tracking" : "Pause tracking",
                    systemImage: faceTrackingPaused ? "play.circle" : "pause.circle") {
                    Task {
                        faceTrackingPaused.toggle()
                        await services.setFaceTrackingEnabled(!faceTrackingPaused)
                    }
                }

                Divider().padding(.vertical, 6)

                row(label: "Wake robot", systemImage: "sun.max") {
                    Task { await services.wakeRobot() }
                }
                row(label: "Sleep robot", systemImage: "moon") {
                    Task { await services.sleepRobot() }
                }

                Divider().padding(.vertical, 6)

                row(label: "Quit Rocky", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 4).padding(.bottom, 6)
        }
        .frame(width: 240)
    }

    @ViewBuilder
    private func row(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 4).padding(.horizontal, 8)
        }
        .buttonStyle(.borderless)
    }

    private var stateLabel: String {
        switch services.rockyState {
        case .sleeping: "asleep"
        case .waking: "waking up…"
        case .idle: "idle"
        case .listening: "listening"
        case .thinking: "thinking"
        case .speaking: "speaking"
        case .error(let msg): msg
        }
    }
}

private struct StateBadge: View {
    let state: AppServices.RockyState

    @State private var pulse: Double = 1
    @State private var bars: [Double] = [0.4, 0.8, 0.5, 1.0]

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
            Circle()
                .strokeBorder(color, lineWidth: 1.6)

            switch state {
            case .sleeping:
                Image(systemName: "moon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(color)
            case .waking:
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, options: .repeating)
            case .idle:
                Circle().fill(color).frame(width: 7, height: 7)
            case .listening:
                Circle()
                    .strokeBorder(color, lineWidth: 1.2)
                    .scaleEffect(pulse)
                    .opacity(2 - pulse)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                            pulse = 1.6
                        }
                    }
            case .thinking:
                Image(systemName: "circle.dotted")
                    .font(.system(size: 14))
                    .symbolEffect(.rotate, options: .repeating)
                    .foregroundStyle(color)
            case .speaking:
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().fill(color)
                            .frame(width: 2, height: max(3, bars[i] * 10))
                    }
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) {
                        bars = [0.9, 0.5, 1.0, 0.6]
                    }
                }
            case .error:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.red)
            }
        }
    }

    private var color: Color {
        switch state {
        case .sleeping:   .gray
        case .waking:     .yellow
        case .idle:       .secondary
        case .listening:  .green
        case .thinking:   .orange
        case .speaking:   .blue
        case .error:      .red
        }
    }
}
