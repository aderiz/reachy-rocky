import SwiftUI

struct VoiceCard: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Card {
            CardHeader("Voice", icon: "waveform") {
                if !services.sttBackendName.isEmpty {
                    Text(services.sttBackendName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                conversationPill
                Button {
                    Task { await services.toggleMic() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: services.micEnabled ? "stop.fill" : "mic.fill")
                        Text(services.micEnabled ? "Stop" : "Listen")
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(services.micEnabled
                                       ? Color.red.opacity(0.18)
                                       : Color.green.opacity(0.18))
                    )
                    .foregroundStyle(services.micEnabled ? .red : .green)
                }
                .buttonStyle(.plain)
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                VUMeter(level: CGFloat(min(1, services.lastMicRMS * 8)),
                        active: services.micEnabled)
                    .frame(height: 22)

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Last transcript")
                    Text(transcriptText)
                        .font(.callout)
                        .foregroundStyle(transcriptStyle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.gray.opacity(0.06))
                        )

                    if !services.lastTranscript.isEmpty {
                        if services.lastDispatched == services.lastTranscript {
                            Label("Routed to brain", systemImage: "arrow.right.circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        } else {
                            Label("Not dispatched — say \u{201C}Rocky, \u{2026}\u{201D}",
                                  systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let err = services.voiceErrorMessage {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var transcriptText: String {
        services.lastTranscript.isEmpty
            ? "\u{2014}"   // em dash placeholder
            : "\u{201C}\(services.lastTranscript)\u{201D}"
    }

    private var transcriptStyle: Color {
        services.lastTranscript.isEmpty ? .secondary : .primary
    }

    @ViewBuilder
    private var conversationPill: some View {
        if services.isAsleep {
            StatusPill(text: "asleep \u{2014} tap or say \u{201C}Rocky\u{201D} to wake",
                       tint: .secondary,
                       systemImage: "moon.fill")
        } else if let until = services.conversationOpenUntil {
            let secs = max(0, Int(until.timeIntervalSinceNow))
            StatusPill(text: "listening · \(secs)s", tint: .green,
                       systemImage: "mic.fill")
        } else if services.micEnabled {
            StatusPill(text: "waiting for wake word", tint: .secondary,
                       systemImage: "ear")
        } else {
            EmptyView()
        }
    }
}

private struct VUMeter: View {
    let level: CGFloat            // 0...1
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.gray.opacity(0.10))
                if active {
                    LinearGradient(
                        colors: [.green, .yellow, .red],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: max(4, level * geo.size.width))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .animation(.easeOut(duration: 0.06), value: level)
                }
            }
        }
    }
}
