import SwiftUI

struct BrainCard: View {
    @Environment(AppServices.self) private var services
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("Brain", systemImage: "brain")
                    .font(.headline)
                Spacer()
                statusPill
                Button {
                    Task { await services.resetBrain() }
                } label: {
                    Label("Reset", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Clear the conversation")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if services.brainTurns.isEmpty {
                            Text("Type below or say \"Rocky, …\" to start a conversation.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        }
                        ForEach(services.brainTurns) { turn in
                            TurnRow(turn: turn).id(turn.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 220)
                .onChange(of: services.brainTurns.last?.id) { _, newId in
                    if let id = newId {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Ask Rocky…", text: $draft, axis: .horizontal)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                Button("Send") { send() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty
                              || services.brainBusy)
            }

            if let err = services.brainErrorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusPill: some View {
        switch services.llmStatus {
        case .unknown:
            return AnyView(Pill(text: "checking…", tint: .gray))
        case .online(let model):
            return AnyView(Pill(text: model, tint: .green))
        case .offline(let reason):
            // Truncate to keep the pill compact; full reason in the help tip.
            let short = reason.split(separator: ":").last.map(String.init) ?? reason
            return AnyView(
                Pill(text: "offline · \(short.prefix(40))", tint: .red)
                    .help(reason)
            )
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await services.sendUserText(text) }
    }
}

private struct TurnRow: View {
    let turn: AppServices.BrainTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                roleBadge
                if let first = turn.firstChunkMs {
                    Pill(text: "TTFT \(Int(first))ms", tint: .secondary)
                }
                if let total = turn.totalMs {
                    Pill(text: "\(Int(total))ms", tint: .secondary)
                }
            }
            Text(turn.content)
                .font(turn.role == "tool" ? .caption.monospaced() : .body)
                .foregroundStyle(turn.role == "tool" ? .secondary : .primary)
            if let detail = turn.detail {
                DisclosureGroup {
                    Text(detail)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                } label: {
                    Text("detail")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var roleBadge: some View {
        switch turn.role {
        case "user":      Pill(text: "you",       tint: .blue)
        case "assistant": Pill(text: "rocky",     tint: .accentColor)
        case "tool":      Pill(text: "tool",      tint: .orange)
        default:          Pill(text: turn.role,   tint: .gray)
        }
    }
}

private struct Pill: View {
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
