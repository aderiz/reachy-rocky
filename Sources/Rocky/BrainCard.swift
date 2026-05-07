import SwiftUI

struct BrainCard: View {
    @Environment(AppServices.self) private var services
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        Card {
            CardHeader("Brain", icon: "brain") {
                statusPill
                Button {
                    Task { await services.resetBrain() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Clear conversation")
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if services.brainTurns.isEmpty {
                    EmptyState(
                        title: "Talk to Rocky",
                        message: "Type below — or with the mic on, just say \u{201C}Rocky\u{2026}\u{201D}"
                    )
                } else {
                    transcript
                }

                inputBar
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(services.brainTurns) { turn in
                        TurnRow(turn: turn).id(turn.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 240)
            .onChange(of: services.brainTurns.last?.id) { _, newId in
                if let id = newId {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask Rocky\u{2026}", text: $draft, axis: .horizontal)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.gray.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            inputFocused ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.20),
                            lineWidth: inputFocused ? 1.5 : 1
                        )
                )
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send() }

            if services.brainBusy {
                ProgressView().controlSize(.small).padding(.horizontal, 4)
            }

            Button {
                send()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.body.weight(.medium))
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(
                            draft.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.gray.opacity(0.15)
                                : Color.accentColor
                        )
                    )
                    .foregroundStyle(
                        draft.trimmingCharacters(in: .whitespaces).isEmpty
                            ? Color.secondary : .white
                    )
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch services.llmStatus {
        case .unknown:
            StatusPill(text: "checking\u{2026}", tint: .secondary, systemImage: "ellipsis")
        case .online(let model):
            StatusPill(text: model, tint: .green, systemImage: "bolt.fill")
        case .offline(let reason):
            let short = String((reason.split(separator: ":").last
                                .map(String.init) ?? reason).prefix(40))
            StatusPill(text: "offline · \(short)", tint: .red,
                       systemImage: "exclamationmark.triangle.fill")
                .help(reason)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        draft = ""
        inputFocused = true
        Task { await services.sendUserText(text) }
    }
}

private struct EmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.body.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
    }
}

private struct TurnRow: View {
    let turn: AppServices.BrainTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                roleBadge
                Spacer()
                if let first = turn.firstChunkMs {
                    Text("TTFT \(Int(first))ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let total = turn.totalMs {
                    Text("\(Int(total))ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(turn.content)
                .font(turn.role == "tool" ? .caption.monospaced() : .body)
                .foregroundStyle(turn.role == "tool" ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail = turn.detail {
                DisclosureGroup {
                    Text(detail)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    Text("detail")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowBackground)
        )
    }

    private var rowBackground: Color {
        switch turn.role {
        case "user":      Color.blue.opacity(0.07)
        case "assistant": Color.accentColor.opacity(0.07)
        case "tool":      Color.orange.opacity(0.06)
        default:          Color.gray.opacity(0.06)
        }
    }

    @ViewBuilder
    private var roleBadge: some View {
        switch turn.role {
        case "user":      StatusPill(text: "you",   tint: .blue,        systemImage: "person.fill")
        case "assistant": StatusPill(text: "rocky", tint: .accentColor, systemImage: "sparkles")
        case "tool":      StatusPill(text: "tool",  tint: .orange,      systemImage: "wrench.fill")
        default:          StatusPill(text: turn.role, tint: .gray)
        }
    }
}
