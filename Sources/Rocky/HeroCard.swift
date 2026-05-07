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
                ReachyHead3D(
                    state: state,
                    pose: services.lastRobotState?.headPose,
                    antennas: services.lastRobotState?.antennasPosition
                )
                // 280 makes the head genuinely heroic in the wide card.
                .frame(width: 280, height: 280)
                .padding(.leading, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Rocky")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    HStack(spacing: 8) {
                        BotModeBadge(mode: services.botMode)
                        Text(label(for: state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    wakeSleepButton(state: state)
                    HStack(spacing: 10) {
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
                }
                .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Big primary affordance — flips between "Wake Rocky" (when asleep)
    /// and a smaller "Sleep" action (when awake). Disabled while a wake/
    /// sleep transition is in flight.
    @ViewBuilder
    private func wakeSleepButton(state: AppServices.RockyState) -> some View {
        let isAsleep = (state == .sleeping)
        let isTransitioning = (state == .waking)
        Button {
            Task {
                if isAsleep {
                    await services.wakeRobot()
                } else {
                    await services.sleepRobot()
                }
            }
        } label: {
            HStack(spacing: 8) {
                if isTransitioning {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Waking\u{2026}")
                } else if isAsleep {
                    Image(systemName: "sun.max.fill")
                        .font(.body.weight(.semibold))
                    Text("Wake Rocky").fontWeight(.semibold)
                } else {
                    Image(systemName: "moon.fill")
                    Text("Sleep").fontWeight(.medium)
                }
            }
            .foregroundStyle(isAsleep ? Color.white : Color.primary)
            .padding(.horizontal, isAsleep ? 18 : 14)
            .padding(.vertical, isAsleep ? 11 : 8)
            .background(
                Capsule().fill(
                    isAsleep ? AnyShapeStyle(LinearGradient(
                        colors: [.orange, .yellow],
                        startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(Color.gray.opacity(0.12))
                )
            )
            .overlay(
                Capsule().stroke(isAsleep ? .orange.opacity(0.5) : .gray.opacity(0.25),
                                 lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isTransitioning)
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
        case .sleeping:            "Asleep \u{2014} tap Wake to bring him up"
        case .waking:              "Waking up\u{2026}"
        case .idle:                "Ready. Say \u{201C}Rocky\u{2026}\u{201D} or use the chat."
        case .tracking:
            if let name = services.lastFaceDetection?.identity {
                "Watching \(name)"
            } else {
                "Watching you"
            }
        case .listening:           "Listening\u{2026}"
        case .thinking:            "Thinking\u{2026}"
        case .speaking:            "Speaking"
        case .error:               "Something needs attention"
        }
    }

    private func color(for state: AppServices.RockyState) -> Color {
        switch state {
        case .sleeping:   .secondary
        case .waking:     .yellow
        case .idle:       .secondary
        case .tracking:   .accentColor
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

/// Big pill that shows the four-state top-level bot mode prominently
/// next to the title. Sub-states (listening/thinking/speaking) appear
/// as the smaller secondary label alongside.
private struct BotModeBadge: View {
    let mode: AppServices.BotMode

    var body: some View {
        let (text, color, symbol) = labelTuple()
        return HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.15)))
        .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 1))
    }

    private func labelTuple() -> (String, Color, String) {
        switch mode {
        case .sleeping: return ("Sleeping", .gray,        "moon.fill")
        case .idle:     return ("Idle",     .secondary,   "circle.dotted")
        case .active:   return ("Watching", .accentColor, "viewfinder")
        case .engaged:  return ("Engaged",  .green,       "waveform")
        case .error:    return ("Error",    .red,         "exclamationmark.triangle.fill")
        }
    }
}
