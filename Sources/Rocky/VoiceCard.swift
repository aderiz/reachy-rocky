import SwiftUI

struct VoiceCard: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("Voice", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Text("STT: \(services.sttBackendName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                conversationPill
                Button {
                    Task { await services.toggleMic() }
                } label: {
                    Label(
                        services.micEnabled ? "Stop listening" : "Start listening",
                        systemImage: services.micEnabled
                            ? "mic.slash.fill" : "mic.fill"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            HStack(alignment: .top, spacing: 16) {
                VUMeter(level: CGFloat(min(1, services.lastMicRMS * 8)))
                    .frame(width: 96, height: 64)

                VStack(alignment: .leading, spacing: 4) {
                    if let err = services.voiceErrorMessage {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Text("Last transcript")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(services.lastTranscript.isEmpty
                         ? "—"
                         : "\u{201C}\(services.lastTranscript)\u{201D}")
                        .font(.body)
                        .textSelection(.enabled)
                        .lineLimit(2)

                    if !services.lastTranscript.isEmpty {
                        if services.lastDispatched == services.lastTranscript {
                            Text("→ dispatched to brain")
                                .font(.caption.monospaced())
                                .foregroundStyle(.green)
                        } else {
                            Text("(no wake word \u{2014} say \u{201C}Rocky, \u{2026}\u{201D})")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var conversationPill: some View {
        if let until = services.conversationOpenUntil {
            let secs = max(0, Int(until.timeIntervalSinceNow))
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("listening · \(secs)s")
                    .font(.caption.monospaced())
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
        } else {
            HStack(spacing: 4) {
                Circle().fill(.gray).frame(width: 6, height: 6)
                Text("waiting for wake word")
                    .font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

private struct VUMeter: View {
    let level: CGFloat        // 0 .. 1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.gray.opacity(0.15))
                LinearGradient(
                    colors: [.green, .yellow, .red],
                    startPoint: .bottom, endPoint: .top
                )
                .frame(height: max(2, level * geo.size.height))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
