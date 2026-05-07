import SwiftUI

/// Hero card. Five visual states tied to `AppServices.rockyState`:
///   .idle      — slow breathing dot, "Idle"
///   .listening — concentric ring pulse, "Listening"
///   .thinking  — circular spinner, "Thinking"
///   .speaking  — staggered four-bar VU animation, "Speaking"
///   .error     — red ring, message
///
/// Three latency pills surface honest TTFT/STT/TTS-first-chunk timings
/// when known (per the plan's "latency-honest" UX principle).
struct HeroCard: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let state = services.rockyState

        HStack(alignment: .top, spacing: 16) {
            HeroIcon(state: state)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text("Rocky")
                    .font(.title2.weight(.semibold))

                Text(label(for: state))
                    .font(.subheadline)
                    .foregroundStyle(color(for: state))

                HStack(spacing: 6) {
                    if let llm = lastLLMTotalMs {
                        Pill(label: "LLM", ms: llm, tint: .accentColor)
                    }
                    if let stt = lastSTTMs {
                        Pill(label: "STT", ms: stt, tint: .teal)
                    }
                    if let tts = lastTTSFirstChunkMs {
                        Pill(label: "TTS", ms: tts, tint: .indigo)
                    }
                }
                .padding(.top, 2)
            }
            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                actionRow
                if case .error(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 220, alignment: .trailing)
                }
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            ActionChip(systemImage: services.micEnabled ? "mic.slash.fill" : "mic.fill",
                       label: services.micEnabled ? "Mute mic" : "Listen") {
                Task { await services.toggleMic() }
            }
            ActionChip(systemImage: services.ttsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       label: services.ttsMuted ? "Unmute" : "Mute voice") {
                Task { await services.toggleTTSMute() }
            }
        }
    }

    private func label(for state: AppServices.RockyState) -> String {
        switch state {
        case .idle:                "Idle"
        case .listening:           "Listening"
        case .thinking:            "Thinking"
        case .speaking:            "Speaking"
        case .error:               "Error"
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

    private var lastSTTMs: Double? {
        // We don't store STT latency directly on AppServices yet; return nil
        // until we lift it through the VoiceCoordinator. Pill is hidden.
        nil
    }

    private var lastTTSFirstChunkMs: Double? {
        // RobotTTS.lastStats.synthMs is on the actor; we mirror it via the
        // `ttsBusyUntil` setter, but for now keep this empty so we don't lie.
        nil
    }
}

private struct HeroIcon: View {
    let state: AppServices.RockyState
    @State private var phase: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(borderColor, lineWidth: 2)
            switch state {
            case .idle:
                Circle()
                    .fill(.thinMaterial)
                    .frame(width: 24 + breath * 12, height: 24 + breath * 12)
            case .listening:
                ListeningPulse()
            case .thinking:
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.regular)
            case .speaking:
                SpeakingBars()
            case .error:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.red)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: stateKey)
        .onAppear { animateBreathing() }
    }

    private var stateKey: String {
        switch state {
        case .idle: "idle"
        case .listening: "listening"
        case .thinking: "thinking"
        case .speaking: "speaking"
        case .error: "error"
        }
    }

    private var borderColor: Color {
        switch state {
        case .idle:      .gray.opacity(0.6)
        case .listening: .green
        case .thinking:  .orange
        case .speaking:  .blue
        case .error:     .red
        }
    }

    private var breath: Double {
        // Slow breathing in idle.
        (sin(phase) + 1) / 2
    }

    private func animateBreathing() {
        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
            phase = .pi
        }
    }
}

private struct ListeningPulse: View {
    @State private var scale: Double = 0.5

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.green, lineWidth: 1.5)
                .scaleEffect(scale)
                .opacity(2 - scale)
            Circle()
                .fill(.green.opacity(0.15))
                .frame(width: 18, height: 18)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                scale = 1.5
            }
        }
    }
}

private struct SpeakingBars: View {
    @State private var heights: [Double] = [0.3, 0.6, 0.9, 0.5]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(.blue)
                    .frame(width: 4, height: max(6, heights[i] * 24))
            }
        }
        .frame(height: 28)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                heights = [0.9, 0.4, 0.7, 1.0]
            }
        }
    }
}

private struct ActionChip: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(label)
    }
}

private struct Pill: View {
    let label: String
    let ms: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text("\(label) \(Int(ms))ms")
                .font(.caption2.monospacedDigit())
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
