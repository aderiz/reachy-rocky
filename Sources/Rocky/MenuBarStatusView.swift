import SwiftUI

/// Menu bar surface. Every label, icon, and toggle binds to the same
/// `AppServices` observable that drives the main window — there is no
/// local `@State` for app behaviour here, so the menu and the dashboard
/// stay in lockstep regardless of which one the user interacted with
/// last.
struct MenuBarStatusView: View {
    @Environment(AppServices.self) private var services

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
                row(label: services.faceTrackingEnabled ? "Pause tracking" : "Resume tracking",
                    systemImage: services.faceTrackingEnabled ? "pause.circle" : "play.circle") {
                    let next = !services.faceTrackingEnabled
                    Task { await services.setFaceTrackingEnabled(next) }
                }

                Divider().padding(.vertical, 6)

                // Single contextual wake/sleep row — matches the
                // dashboard's HeroCard button so the menu and main
                // window present the same affordance for the same state.
                wakeSleepRow(state: services.rockyState)

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
    private func wakeSleepRow(state: AppServices.RockyState) -> some View {
        switch state {
        case .sleeping, .error:
            row(label: "Wake Rocky", systemImage: "sun.max.fill") {
                Task { await services.wakeRobot() }
            }
        case .waking:
            row(label: "Waking\u{2026}", systemImage: "hourglass") { }
        default:
            row(label: "Sleep Rocky", systemImage: "moon.fill") {
                Task { await services.sleepRobot() }
            }
        }
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
        case .waking: "waking up\u{2026}"
        case .idle: "idle"
        case .tracking:
            if let name = services.lastFaceDetection?.identity {
                "watching \(name)"
            } else {
                "watching you"
            }
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
            case .tracking:
                Image(systemName: "viewfinder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(color)
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
        case .tracking:   .accentColor
        case .listening:  .green
        case .thinking:   .orange
        case .speaking:   .blue
        case .error:      .red
        }
    }
}
