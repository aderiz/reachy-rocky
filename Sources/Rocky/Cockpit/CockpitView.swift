import SwiftUI

/// Cockpit prototype — centre column only.
///
/// The cockpit is where you sit when you're working WITH Rocky, not
/// monitoring him. Today's Dashboard is preserved as-is alongside
/// this view; the cockpit is added as a sibling sidebar entry so we
/// can iterate without disturbing what works.
///
/// This file is intentionally a single self-contained view for the
/// prototype. Once the centre column is right, situation (left)
/// and controls (right) get added around it.
///
/// Layout, top to bottom:
///
///   ┌────────────────────────────────────────────┐
///   │  presence pill   ·   one-line state         │   header
///   │  ─────────────────────────────────────────  │
///   │  mic VU + STT live partial                  │   "what he hears now"
///   │  ─────────────────────────────────────────  │
///   │                                             │
///   │  conversation transcript (scrollable)       │   centre of attention
///   │                                             │
///   │  ─────────────────────────────────────────  │
///   │  ╭ ask Rocky… ─────────────────────────╮ ⏎ │   text input
///   │  ╰─────────────────────────────────────╯    │
///   │  ╭ remember: ──────────────────────────╮ ⓟ │   inline memory write
///   │  ╰─────────────────────────────────────╯    │
///   │  ◀ replay 30s          ⓘ why no reply?      │   utility row
///   │  ─────────────────────────────────────────  │
///   │  diagnose card (only when last turn failed) │
///   └────────────────────────────────────────────┘
struct CockpitView: View {
    @Environment(AppServices.self) private var services
    @State private var ask: String = ""
    @State private var remember: String = ""
    @State private var rememberConfirmation: String?
    @State private var pinNext: Bool = false
    @State private var showReplay: Bool = false
    @State private var showDiagnose: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 12)
            Divider().opacity(0.10)
            HearingStrip()
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            Divider().opacity(0.10)
            TranscriptArea(showReplay: $showReplay)
                .padding(.horizontal, 24)
            Divider().opacity(0.10)
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cockpit")
                    .font(.title2.weight(.semibold))
                Text(presenceLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statePill
        }
    }

    private var presenceLine: String {
        switch services.botMode {
        case .sleeping:  return "Rocky is asleep — say his name to wake."
        case .idle:      return "Rocky is awake but not paying attention to you yet."
        case .active:    return "Rocky is watching."
        case .engaged:   return "Rocky is listening to you."
        case .error(let reason): return "Rocky needs a hand — \(reason)"
        }
    }

    private var statePill: some View {
        let (text, tint, icon) = stateTuple
        return StatusPill(text: text, tint: tint, systemImage: icon)
    }

    private var stateTuple: (String, Color, String) {
        switch services.rockyState {
        case .sleeping:  return ("asleep", .secondary, "moon.fill")
        case .waking:    return ("waking", .orange, "sunrise")
        case .idle:      return ("idle", .secondary, "circle")
        case .tracking:  return ("watching", .green, "eye.fill")
        case .listening: return ("listening", .green, "ear.fill")
        case .thinking:  return ("thinking", .blue, "brain")
        case .speaking:  return ("speaking", .orange, "waveform")
        case .error:     return ("error", .red, "exclamationmark.triangle.fill")
        }
    }

    // MARK: - Footer (input + utility row + diagnose)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            askInputRow
            rememberInputRow
            utilityRow
            if showDiagnose {
                DiagnoseCard()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showDiagnose)
    }

    private var askInputRow: some View {
        HStack(spacing: 8) {
            TextField("ask Rocky…", text: $ask)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.gray.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.gray.opacity(0.18), lineWidth: 1)
                )
                .onSubmit { submitAsk() }
            Button {
                submitAsk()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(ask.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Send (⏎). Goes through the same brain pipeline as voice.")
        }
    }

    private var rememberInputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: pinNext ? "pin.fill" : "pin")
                .foregroundStyle(pinNext ? .yellow : .secondary)
                .onTapGesture { pinNext.toggle() }
                .help(pinNext
                      ? "Will pin this memory (always recalled)."
                      : "Click to pin: this memory will always be recalled.")
            TextField("remember: a fact, preference, or note about \(activePerson)…",
                      text: $remember)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.yellow.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.yellow.opacity(0.20), lineWidth: 1)
                )
                .onSubmit { submitRemember() }
            if let confirmation = rememberConfirmation {
                Text(confirmation)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: rememberConfirmation)
    }

    private var utilityRow: some View {
        HStack(spacing: 14) {
            Button {
                showReplay.toggle()
            } label: {
                Label(showReplay ? "hide replay" : "replay 30s",
                      systemImage: showReplay
                        ? "rectangle.compress.vertical"
                        : "gobackward.30")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Show or hide the last 30 seconds of conversation history.")

            Button {
                showDiagnose.toggle()
            } label: {
                Label(showDiagnose ? "hide diagnose" : "why no reply?",
                      systemImage: "stethoscope")
                    .foregroundStyle(diagnoseTint)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Show what happened to your last spoken utterance.")

            Spacer()

            if let until = services.conversationOpenUntil {
                let secs = max(0, Int(until.timeIntervalSinceNow))
                StatusPill(text: "listening · \(secs)s", tint: .green,
                           systemImage: "mic.fill")
            }
        }
    }

    private var diagnoseTint: Color {
        services.lastTranscript.isEmpty ? .secondary
            : (services.lastDispatched == services.lastTranscript ? .green : .orange)
    }

    private var activePerson: String {
        services.lastFaceDetection?.identity ?? "the user"
    }

    // MARK: - Actions

    private func submitAsk() {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ask = ""
        Task { await services.sendUserText(text) }
    }

    private func submitRemember() {
        let text = remember.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let body = pinNext ? "[pinned] " + text : text
        remember = ""
        Task {
            do {
                _ = try await services.memory.record(role: .system, text: body)
                await MainActor.run {
                    rememberConfirmation = "filed ✓"
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
}

// MARK: - Hearing strip (mic VU + live STT partial)

/// What Rocky's hearing right now. The VU reflects mic energy; the
/// caption shows the rolling STT partial. Wake-state badge on the
/// right tells you whether Rocky is paying attention.
private struct HearingStrip: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: 14) {
            VUMeter(level: CGFloat(min(1, services.lastMicRMS * 8)),
                    active: services.micEnabled)
                .frame(width: 110, height: 8)

            Text(captionText)
                .font(.callout)
                .foregroundStyle(captionTint)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            wakeBadge
        }
    }

    private var captionText: String {
        if !services.micEnabled { return "mic off" }
        let text = services.lastTranscript
        return text.isEmpty ? "—" : "\u{201C}\(text)\u{201D}"
    }

    private var captionTint: Color {
        if !services.micEnabled { return .secondary }
        return services.lastTranscript.isEmpty ? .secondary : .primary
    }

    @ViewBuilder
    private var wakeBadge: some View {
        if !services.micEnabled {
            StatusPill(text: "mic off", tint: .secondary,
                       systemImage: "mic.slash")
        } else if let until = services.conversationOpenUntil {
            let secs = max(0, Int(until.timeIntervalSinceNow))
            StatusPill(text: "open · \(secs)s", tint: .green,
                       systemImage: "ear.fill")
        } else {
            StatusPill(text: "say \u{201C}Rocky\u{201D}", tint: .secondary,
                       systemImage: "ear")
        }
    }
}

private struct VUMeter: View {
    let level: CGFloat
    let active: Bool
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.gray.opacity(0.12))
                if active {
                    LinearGradient(
                        colors: [.green, .yellow, .red],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: max(2, level * geo.size.width))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .animation(.easeOut(duration: 0.06), value: level)
                }
            }
        }
    }
}

// MARK: - Transcript

/// Conversation transcript. When `showReplay` is on, we render a
/// timestamp-bracketed copy of the last 30 seconds at the top —
/// proxy for the eventual full audio replay.
private struct TranscriptArea: View {
    @Environment(AppServices.self) private var services
    @Binding var showReplay: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if showReplay { replayPanel }
                    if services.brainTurns.isEmpty {
                        emptyState
                            .padding(.vertical, 60)
                    } else {
                        ForEach(services.brainTurns) { turn in
                            TurnBubble(turn: turn)
                                .id(turn.id)
                        }
                    }
                }
                .padding(.vertical, 14)
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
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary.opacity(0.6))
            Text("Nothing yet. Say Rocky's name, or type below.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Recent transcript window. For the prototype we just slice the
    /// last few brainTurns; once we have a real rolling audio buffer
    /// this gets replaced with `[mic clip · stt · brain · tts clip]`.
    private var replayPanel: some View {
        let recent = Array(services.brainTurns.suffix(6))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "gobackward.30")
                Text("Last \(recent.count) entries")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("audio replay coming soon")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            ForEach(recent) { t in
                Text("\(t.role): \(t.content)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.gray.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.gray.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct TurnBubble: View {
    let turn: AppServices.BrainTurn

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            roleAvatar
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(roleLabel)
                        .font(.caption.weight(.semibold))
                    if let total = turn.totalMs {
                        Text(String(format: "%.0f ms", total))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(turn.content.isEmpty ? "…" : turn.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = turn.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(bubbleTint.opacity(0.10))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var roleAvatar: some View {
        Circle()
            .fill(bubbleTint.opacity(0.22))
            .overlay(
                Image(systemName: roleIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(bubbleTint)
            )
    }

    private var roleLabel: String {
        switch turn.role {
        case "user":      return "you"
        case "assistant": return "Rocky"
        case "tool":      return "tool"
        default:          return turn.role
        }
    }

    private var roleIcon: String {
        switch turn.role {
        case "user":      return "person.fill"
        case "assistant": return "brain"
        case "tool":      return "wrench.and.screwdriver.fill"
        default:          return "circle"
        }
    }

    private var bubbleTint: Color {
        switch turn.role {
        case "user":      return .accentColor
        case "assistant": return .green
        case "tool":      return .purple
        default:          return .secondary
        }
    }
}

// MARK: - Diagnose card

/// "Why didn't Rocky reply?" — surfaces the stage that closed the
/// last user utterance. Heuristic for the prototype; once we tag
/// utterances at every stage in the pipeline, this card becomes
/// authoritative.
private struct DiagnoseCard: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let stages = stageStatuses()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "stethoscope")
                Text("Last utterance — what happened")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(verdict)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(verdictTint)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(stages, id: \.label) { stage in
                    HStack(spacing: 8) {
                        Image(systemName: stage.icon)
                            .foregroundStyle(stage.tint)
                            .frame(width: 14)
                        Text(stage.label)
                            .font(.caption.weight(.medium))
                        Text(stage.detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
            if let err = services.brainErrorMessage ?? services.voiceErrorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.orange.opacity(0.18), lineWidth: 1)
        )
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
        let dispatched = services.lastDispatched == transcript
            && !transcript.isEmpty
        let brainOK = services.brainErrorMessage == nil

        return [
            mk("Mic", micOK ? "live" : "off", micOK),
            mk("STT",
               transcript.isEmpty ? "no final transcript yet" : "\u{201C}\(transcript)\u{201D}",
               !transcript.isEmpty),
            mk("Wake filter",
               dispatched ? "matched — sent to brain"
                          : (transcript.isEmpty ? "—"
                                                 : "no wake word — say \u{201C}Rocky\u{201D}"),
               dispatched),
            mk("Brain",
               services.brainBusy ? "thinking…"
                                  : (services.brainErrorMessage ?? "ok"),
               brainOK),
            mk("TTS",
               services.ttsMuted ? "muted" : "ok",
               !services.ttsMuted),
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
            return firstFail.label.lowercased()
        }
        return "all clear"
    }

    private var verdictTint: Color {
        stageStatuses().allSatisfy(\.ok) ? .green : .orange
    }
}
