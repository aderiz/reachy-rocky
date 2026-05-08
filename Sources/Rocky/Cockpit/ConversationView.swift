import SwiftUI

/// ConversationView — the stage's right column.
///
/// Per `docs/concepts/cockpit-design.md` §3.1, the conversation lives
/// alongside the portrait and is the only place text is read or
/// composed. Subsumes BrainCard + VoiceCard + the rejected centre-column
/// prototype.
///
/// Layout, top to bottom:
///
///   - Hearing strip — slim VU + the rolling STT partial in `.callout`
///     (italic when listening), or a quiet "say Rocky to start" hint.
///   - Transcript — bubble-shaped `services.brainTurns`. User bubbles
///     accent-tinted right-aligned, Rocky's primary-tinted left-aligned.
///     Tool calls render as a thin pill between bubbles.
///   - Input row — TextField "Ask Rocky, or say his name" with a
///     leading mic toggle (mirrors the toolbar's; redundant on purpose
///     so the input strip is self-contained) and a trailing send button.
struct ConversationView: View {
    @Environment(AppServices.self) private var services
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HearingStrip()
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)
            Divider().opacity(0.10)
            transcript
            Divider().opacity(0.10)
            inputRow
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if services.brainTurns.isEmpty {
                        emptyState.padding(.vertical, 80)
                    } else {
                        ForEach(services.brainTurns) { turn in
                            ConversationBubble(turn: turn)
                                .id(turn.id)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: services.brainTurns.last?.id) { _, newId in
                guard let newId else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(newId, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Say Rocky's name or type below.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 10) {
            // Leading mic toggle. The toolbar carries the same control,
            // but a self-contained input strip is the macOS chat
            // convention (Messages, Slack). Both stay in lockstep
            // because they read the same observable.
            Button {
                Task { await services.toggleMic() }
            } label: {
                Image(systemName: services.micEnabled ? "mic.fill" : "mic.slash")
                    .font(.headline)
                    .foregroundStyle(services.micEnabled
                                       ? AnyShapeStyle(.tint)
                                       : AnyShapeStyle(.secondary))
                    .symbolEffect(.pulse, options: .repeating,
                                  isActive: services.micEnabled
                                              && services.conversationOpenUntil != nil)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(services.micEnabled
                  ? "Stop listening — toolbar carries the same control."
                  : "Start listening so Rocky can hear you say his name.")

            TextField("Ask Rocky, or say his name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit { send() }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty
                      || services.brainBusy)
            .help("Send (⏎ or ⌘⏎). Goes through the same brain pipeline as voice.")
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await services.sendUserText(text) }
    }
}

// MARK: - Hearing strip

/// Slim VU + rolling STT partial. Sits above the transcript. The VU is
/// deliberately small (4pt tall) — it's a hint of energy, not a feature.
private struct HearingStrip: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: 12) {
            VUMeter(level: CGFloat(min(1, services.lastMicRMS * 8)),
                    active: services.micEnabled)
                .frame(width: 56, height: 4)

            Text(captionText)
                .font(.callout)
                .foregroundStyle(captionTint)
                .italic(captionItalic)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            wakeBadge
        }
    }

    private var captionText: String {
        if !services.micEnabled { return "Mic off — toolbar to enable." }
        let text = services.lastTranscript
        if text.isEmpty {
            return services.conversationOpenUntil != nil
                ? "Listening…"
                : "Say Rocky to start."
        }
        return "\u{201C}\(text)\u{201D}"
    }

    private var captionTint: Color {
        if !services.micEnabled { return Color.secondary.opacity(0.6) }
        return services.lastTranscript.isEmpty ? .secondary : .primary
    }

    private var captionItalic: Bool {
        services.micEnabled
            && services.conversationOpenUntil != nil
            && !services.lastTranscript.isEmpty
    }

    @ViewBuilder
    private var wakeBadge: some View {
        if !services.micEnabled {
            EmptyView()
        } else if let until = services.conversationOpenUntil {
            let secs = max(0, Int(until.timeIntervalSinceNow))
            Text("open · \(secs)s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.green)
        } else {
            EmptyView()
        }
    }
}

private struct VUMeter: View {
    let level: CGFloat
    let active: Bool
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.tertiary.opacity(0.4))
                if active {
                    LinearGradient(colors: [.green, .yellow, .red],
                                   startPoint: .leading,
                                   endPoint: .trailing)
                        .frame(width: max(2, level * geo.size.width))
                        .clipShape(Capsule())
                        .animation(.easeOut(duration: 0.06), value: level)
                }
            }
        }
    }
}

// MARK: - Bubble

private struct ConversationBubble: View {
    let turn: AppServices.BrainTurn

    var body: some View {
        switch turn.role {
        case "user":
            HStack {
                Spacer(minLength: 40)
                bubble(alignment: .trailing,
                       tint: .accentColor,
                       roleLabel: "You")
            }
        case "assistant":
            HStack {
                bubble(alignment: .leading,
                       tint: .primary,
                       roleLabel: "Rocky")
                Spacer(minLength: 40)
            }
        case "tool":
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption)
                Text(turn.content)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                if let detail = turn.detail, !detail.isEmpty {
                    Text("· \(detail)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func bubble(alignment: HorizontalAlignment,
                         tint: Color,
                         roleLabel: String) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(turn.content.isEmpty ? "…" : turn.content)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(0.12))
                )
            // Latency caption only on Rocky's bubbles, only on hover —
            // for now we emit it as a quiet always-on caption since
            // SwiftUI doesn't have a great hover-only on macOS without
            // adding state. Keep it small + tertiary so it doesn't
            // demand attention.
            if let total = turn.totalMs, alignment == .leading {
                Text(String(format: "%.0f ms", total))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity,
               alignment: alignment == .trailing ? .trailing : .leading)
        .accessibilityLabel("\(roleLabel) said: \(turn.content)")
    }
}
