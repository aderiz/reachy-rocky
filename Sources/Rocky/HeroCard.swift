import SwiftUI

/// Hero card — Rocky's presence. A real avatar that physically tracks the
/// live head pose + antenna joints, with state-driven facial expressions
/// (eyes open / blink / mouth animation per `RockyState`). Latency pills
/// summarise the loop's honesty (LLM TTFT, STT, TTS first chunk).
struct HeroCard: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let state = services.rockyState

        Card {
            // No header — Rocky himself is the header.
            EmptyView()
        } content: {
            HStack(alignment: .center, spacing: 24) {
                RockyAvatar(
                    state: state,
                    pose: services.lastRobotState?.headPose,
                    antennas: services.lastRobotState?.antennasPosition,
                    size: 140
                )
                .padding(.leading, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Rocky")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text(label(for: state))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(color(for: state))
                    HStack(spacing: 6) {
                        if let llm = lastLLMTotalMs {
                            StatusPill(text: "LLM \(Int(llm))ms", tint: .accentColor)
                        }
                        if let tts = lastTTSFirstChunkMs {
                            StatusPill(text: "TTS \(Int(tts))ms", tint: .indigo)
                        }
                    }
                    if case .error(let message) = state {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }

                Spacer()

                VStack(spacing: 10) {
                    iconButton(
                        services.micEnabled ? "mic.slash.fill" : "mic.fill",
                        active: services.micEnabled,
                        tint: .green
                    ) { Task { await services.toggleMic() } }
                    iconButton(
                        services.ttsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        active: !services.ttsMuted,
                        tint: .blue
                    ) { Task { await services.toggleTTSMute() } }
                }
                .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func iconButton(_ name: String,
                            active: Bool,
                            tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(
                    Circle().fill(active ? tint.opacity(0.18) : .gray.opacity(0.08))
                )
                .overlay(
                    Circle().stroke(active ? tint.opacity(0.5) : .gray.opacity(0.25),
                                    lineWidth: 1)
                )
                .foregroundStyle(active ? tint : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func label(for state: AppServices.RockyState) -> String {
        switch state {
        case .idle:                "Sitting quietly. Say \u{201C}Rocky\u{201D} to start."
        case .listening:           "Listening\u{2026}"
        case .thinking:            "Thinking\u{2026}"
        case .speaking:            "Speaking"
        case .error:               "Something needs attention"
        }
    }

    private func color(for state: AppServices.RockyState) -> Color {
        switch state {
        case .idle:       .secondary
        case .listening:  .green
        case .thinking:   .orange
        case .speaking:   .blue
        case .error:      .red
        }
    }

    private var lastLLMTotalMs: Double? {
        services.brainTurns.reversed().first(where: { $0.role == "assistant" })?.totalMs
    }

    private var lastTTSFirstChunkMs: Double? { nil }
}
