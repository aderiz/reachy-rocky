import SwiftUI

/// CockpitView — the stage.
///
/// Per `docs/concepts/cockpit-design.md` §3.1, the window's primary
/// content is a portrait + conversation split with a draggable divider.
/// `HSplitView` provides the divider and per-side resize behavior.
///
/// Wave 3 replaces the rejected centre-only prototype with the full
/// stage. The "remember:" inline-write and "why no reply?" diagnose
/// affordances move into the *footer* strip — they're useful but not
/// load-bearing, so they sit below the conversation column rather than
/// inside it.
///
/// Default split: ~40 portrait / 60 conversation. The divider can be
/// dragged either way; minimums prevent the columns from collapsing.
struct CockpitView: View {
    @Environment(AppServices.self) private var services
    @State private var rememberDraft: String = ""
    @State private var rememberConfirmation: String?
    @State private var pinNext: Bool = false
    @State private var diagnoseShown: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                PortraitView()
                    .frame(minWidth: 320, idealWidth: 420)
                ConversationView()
                    .frame(minWidth: 480)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.10)
            // The moment-feed strip — the cockpit's quiet margin.
            // Always shows the latest moment; hover expands to four.
            MomentStrip()
            Divider().opacity(0.10)
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer (remember + diagnose)

    /// Sits below both columns so it spans the window. Keeps the
    /// "teach Rocky" affordance discoverable without crowding the
    /// conversation column. The diagnose card expands inline when
    /// summoned.
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
}

// MARK: - Diagnose strip

/// Walks the pipeline stages for the last utterance. Heuristic for now
/// (compares lastTranscript to lastDispatched, reads brain/voice error
/// fields); becomes authoritative once the moment-feed actor tags every
/// turn with the closing stage in Wave 4.
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
