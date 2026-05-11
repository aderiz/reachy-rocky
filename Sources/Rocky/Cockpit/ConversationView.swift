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

    // Footer state lives here (not on CockpitView) because the
    // footer is part of the conversation column per design §3.2 — it
    // tracks the splitter when the user resizes columns. Keeping
    // state with the view that owns it also avoids the long-window
    // rendering bug where the Remember field stretched across the
    // entire window.
    @State private var rememberDraft: String = ""
    @State private var rememberConfirmation: String?
    @State private var pinNext: Bool = false
    @State private var diagnoseShown: Bool = false

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
            Divider().opacity(0.10)
            MomentStrip()
            Divider().opacity(0.10)
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    // MARK: - Footer (remember + diagnose)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            footerRow
            if diagnoseShown {
                DiagnoseStrip()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: diagnoseShown)
    }

    private var footerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: pinNext ? "pin.fill" : "pin")
                .foregroundStyle(pinNext ? .yellow : .secondary)
                .onTapGesture { pinNext.toggle() }
                .help(pinNext
                      ? "Pinned: this memory will always be recalled."
                      : "Click to pin: always recall this memory.")

            TextField("Remember: a fact, preference, or note Rocky should keep…",
                      text: $rememberDraft)
                .textFieldStyle(.roundedBorder)
                // Cap so the field stays a compact input even when
                // the conversation column is wide; the confirmation
                // chip + Why-no-reply button sit beside it and we
                // want them visible together.
                .frame(maxWidth: 360)
                .onSubmit { submitRemember() }

            if let confirmation = rememberConfirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)

            Button {
                diagnoseShown.toggle()
            } label: {
                Label(diagnoseShown ? "Hide diagnose" : "Why no reply?",
                      systemImage: "stethoscope")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Walk the mic / STT / wake / brain / TTS chain for the most recent utterance.")
        }
        .animation(.easeInOut(duration: 0.2), value: rememberConfirmation)
    }

    private func submitRemember() {
        let text = rememberDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let body = pinNext ? "[pinned] " + text : text
        rememberDraft = ""
        Task {
            do {
                _ = try await services.memory.record(role: .system, text: body)
                await MainActor.run {
                    rememberConfirmation = "Filed"
                    pinNext = false
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { rememberConfirmation = nil }
                await services.refreshMemoryCount()
            } catch {
                await MainActor.run {
                    rememberConfirmation = "failed: \(error)"
                }
            }
        }
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
                            if turn.role == "tool",
                               !services.settings.showToolCalls {
                                EmptyView()
                            } else {
                                ConversationBubble(turn: turn)
                                    .id(turn.id)
                            }
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

    /// Hard cap on bubble width. Messages.app and Slack settle around
    /// 60–70% of the column; we use an absolute upper bound so
    /// bubbles stay readable even when the conversation column is
    /// wide. Below this they'll shrink to the content's natural
    /// width — short replies sit as compact pills, long replies wrap
    /// at the cap.
    private static let bubbleMaxWidth: CGFloat = 520

    var body: some View {
        switch turn.role {
        case "user":
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 0)
                bubble(alignment: .trailing,
                       tint: .accentColor,
                       roleLabel: "You")
                    .frame(maxWidth: Self.bubbleMaxWidth, alignment: .trailing)
            }
        case "assistant":
            HStack(alignment: .top, spacing: 0) {
                bubble(alignment: .leading,
                       tint: .primary,
                       roleLabel: "Rocky")
                    .frame(maxWidth: Self.bubbleMaxWidth, alignment: .leading)
                Spacer(minLength: 0)
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
        // The outer caller (`var body`) applies the absolute
        // `bubbleMaxWidth` cap and trailing/leading alignment via the
        // parent HStack. Inside the bubble we just let the Text size
        // naturally — short content stays compact, long content
        // wraps inside the cap.
        VStack(alignment: alignment, spacing: 2) {
            Text(turn.content.isEmpty ? "…" : turn.content)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(0.12))
                )
            if let total = turn.totalMs, alignment == .leading {
                Text(String(format: "%.0f ms", total))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
        .accessibilityLabel("\(roleLabel) said: \(turn.content)")
    }
}

// MARK: - Diagnose strip

/// Walks the pipeline stages for the last utterance. Heuristic for now
/// (compares lastTranscript to lastDispatched, reads brain/voice error
/// fields); becomes authoritative once the moment-feed actor tags every
/// turn with the closing stage in Wave 4.
///
/// Moved into ConversationView.swift alongside the footer that summons
/// it so the cockpit column owns its own diagnose surface end-to-end.
private struct DiagnoseStrip: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let stages = stageStatuses()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "stethoscope")
                    .foregroundStyle(verdictTint)
                Text("Last utterance — what happened")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(verdict)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(verdictTint)
            }
            HStack(alignment: .top, spacing: 18) {
                ForEach(stages, id: \.label) { stage in
                    HStack(spacing: 6) {
                        Image(systemName: stage.icon)
                            .foregroundStyle(stage.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stage.label)
                                .font(.caption.weight(.medium))
                            Text(stage.detail)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            if let err = services.brainErrorMessage ?? services.voiceErrorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private struct Stage {
        let label: String
        let detail: String
        let ok: Bool
        let icon: String
        let tint: Color
    }

    private func stageStatuses() -> [Stage] {
        let micOK = services.micEnabled
        let transcript = services.lastTranscript
        let dispatched = services.lastDispatched == transcript && !transcript.isEmpty
        let brainOK = services.brainErrorMessage == nil
        return [
            mk("Mic",  micOK ? "live" : "off", micOK),
            mk("STT",
               transcript.isEmpty ? "no final yet" : "\u{201C}\(transcript)\u{201D}",
               !transcript.isEmpty),
            mk("Wake",
               dispatched ? "matched"
                          : (transcript.isEmpty ? "—"
                                                 : "no wake word"),
               dispatched),
            mk("Brain",
               services.brainBusy ? "thinking…"
                                   : (services.brainErrorMessage ?? "ok"),
               brainOK),
            mk("TTS",  services.ttsMuted ? "muted" : "ok", !services.ttsMuted),
        ]
    }

    private func mk(_ label: String, _ detail: String, _ ok: Bool) -> Stage {
        Stage(
            label: label,
            detail: detail,
            ok: ok,
            icon: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            tint: ok ? .green : .orange
        )
    }

    private var verdict: String {
        let stages = stageStatuses()
        if let firstFail = stages.first(where: { !$0.ok }) {
            return "stalled at \(firstFail.label.lowercased())"
        }
        return "all clear"
    }

    private var verdictTint: Color {
        stageStatuses().allSatisfy(\.ok) ? .green : .orange
    }
}
