import SwiftUI
import Telemetry

/// Tails the LogBus into an in-memory ring buffer (last N events) and
/// renders a filterable, color-coded list. Same Card chrome as the rest.
struct LogsView: View {
    @Environment(AppServices.self) private var services
    @State private var rows: [Row] = []
    @State private var filter: String = ""
    @State private var paused: Bool = false
    @State private var showCategories: Set<Category> = Set(Category.allCases)

    private let capacity = 500

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Card {
                    CardHeader("Filters", icon: "line.3.horizontal.decrease")
                } content: {
                    filtersBar
                }
                Card {
                    CardHeader("Stream", icon: "waveform") {
                        StatusPill(text: "\(filteredRows.count) of \(rows.count)",
                                   tint: .secondary)
                    }
                } content: {
                    streamView
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 980, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .task {
            let bus = services.logBus
            for await event in await bus.subscribe() {
                if paused { continue }
                let row = Row.from(event)
                await MainActor.run {
                    rows.append(row)
                    if rows.count > capacity {
                        rows.removeFirst(rows.count - capacity)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Logs")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Every event Rocky published, in arrival order.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                paused.toggle()
            } label: {
                Label(paused ? "Resume" : "Pause",
                      systemImage: paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                rows.removeAll()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var filtersBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowHStack(spacing: 8) {
                ForEach(Category.allCases) { cat in
                    let on = showCategories.contains(cat)
                    Button {
                        if on { showCategories.remove(cat) }
                        else  { showCategories.insert(cat) }
                    } label: {
                        StatusPill(
                            text: cat.label,
                            tint: on ? cat.color : .secondary,
                            systemImage: on ? "checkmark" : "circle"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("filter", text: $filter)
                    .textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.gray.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.gray.opacity(0.20), lineWidth: 1)
            )
        }
    }

    private var streamView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredRows) { row in
                        RowView(row: row).id(row.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 480)
            .onChange(of: filteredRows.last?.id) { _, newId in
                guard !paused, let id = newId else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private var filteredRows: [Row] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { r in
            guard showCategories.contains(r.category) else { return false }
            if q.isEmpty { return true }
            return r.summary.lowercased().contains(q)
                || r.detail.lowercased().contains(q)
        }
    }

    enum Category: Sendable, Hashable, Identifiable, CaseIterable {
        case motor, vision, voice, brain, sidecar, link, error
        var id: Self { self }
        var label: String {
            switch self {
            case .motor:   "motor"
            case .vision:  "vision"
            case .voice:   "voice"
            case .brain:   "brain"
            case .sidecar: "sidecar"
            case .link:    "link"
            case .error:   "error"
            }
        }
        var color: Color {
            switch self {
            case .motor:   .blue
            case .vision:  .purple
            case .voice:   .teal
            case .brain:   .accentColor
            case .sidecar: .orange
            case .link:    .gray
            case .error:   .red
            }
        }
    }

    struct Row: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let category: Category
        let summary: String
        let detail: String

        static func from(_ event: TimestampedEvent) -> Row {
            let (cat, summary, detail) = classify(event.event)
            return Row(timestamp: event.timestamp, category: cat,
                       summary: summary, detail: detail)
        }

        private static func classify(_ event: TelemetryEvent) -> (Category, String, String) {
            switch event {
            case .motorCommand(let source, let target):
                let bits = [
                    target.headPose.map {
                        String(format: "yaw=%+.1f° pitch=%+.1f°",
                               $0.yaw * 180 / .pi, $0.pitch * 180 / .pi)
                    },
                    target.antennas.map {
                        String(format: "ant=[%+.0f°,%+.0f°]",
                               $0.right * 180 / .pi, $0.left * 180 / .pi)
                    },
                    target.bodyYaw.map { String(format: "body=%+.1f°", $0 * 180 / .pi) }
                ].compactMap { $0 }.joined(separator: " ")
                return (.motor, "command (\(source.rawValue)) \(bits)", "")
            case .motorState(let s):
                return (.motor,
                        String(format: "state head_yaw=%+.1f° body=%+.1f°",
                               s.headPose.yaw * 180 / .pi, s.bodyYaw * 180 / .pi),
                        "")
            case .stateStream(let t):
                return (.motor, "state-stream \(t)", "")
            case .robotLink(let endpoint, let status, let ms):
                return (.link, String(format: "%@ %d %.0fms", endpoint, status, ms), "")
            case .daemonStatus(let p, _, _):
                return (.link, String(format: "daemon ~%.1fms", p), "")
            case .faceDetection(let bbox, let confidence, let promptId):
                return (.vision,
                        String(format: "detection conf=%.2f", confidence),
                        "\(bbox) prompt=\(promptId)")
            case .faceTarget(let yaw, let pitch, let decay):
                return (.vision,
                        String(format: "target yaw=%+.2f pitch=%+.2f%@",
                               yaw, pitch, decay ? " (decay)" : ""),
                        "")
            case .vadSegment(let start, let end):
                return (.voice, String(format: "vad %.0fms-%.0fms", start, end), "")
            case .sttPartial(let text, _):
                return (.voice, "stt partial: \(text)", "")
            case .sttFinal(let text, let ms):
                return (.voice, String(format: "stt final (%.0fms): \(text)", ms), "")
            case .wakeMatch(let name, let transcript):
                return (.voice, "wake matched '\(name)'", transcript)
            case .conversationWindow(let transition, let reason):
                return (.voice, "conv window \(transition.rawValue) (\(reason))", "")
            case .ttsRequest(let text, let voiceRefId, let firstChunkMs):
                let ms = firstChunkMs.map { String(format: "%.0fms ", $0) } ?? ""
                return (.voice, "tts \(ms)voice=\(voiceRefId)", text)
            case .ttsChunk(let i, let ms, let bytes):
                return (.voice, String(format: "tts chunk #%d %.0fms %dB", i, ms, bytes), "")
            case .llmRequest(let n, let t):
                return (.brain, "llm request msgs=\(n) tools=\(t)", "")
            case .llmChunk(let ms, let content, let tool):
                let body = (content ?? "") + (tool ?? "")
                return (.brain, String(format: "llm chunk +%.0fms", ms), body)
            case .llmToolCall(let name, let args, let id):
                return (.brain, "llm tool_call \(name) [\(id)]", args)
            case .toolInvocation(let name, let args, let result, let ms, _):
                return (.brain,
                        String(format: "tool %@ → %dms", name, Int(ms)),
                        "args=\(args)\nresult=\(result)")
            case .sidecarLog(let sidecar, let level, let message, let fields):
                let f = fields.isEmpty ? "" : "  " + fields
                    .map { "\($0)=\($1)" }
                    .joined(separator: " ")
                return (.sidecar,
                        "[\(sidecar)] \(level.rawValue): \(message)",
                        f)
            case .sidecarState(let sidecar, let transition):
                return (.sidecar, "[\(sidecar)] \(transition)", "")
            case .error(let scope, let message, let recoverable):
                return (.error,
                        "ERROR \(scope): \(message)",
                        recoverable ? "(recoverable)" : "")
            }
        }
    }

    private struct RowView: View {
        let row: Row

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Text(timeString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Rectangle()
                    .fill(row.category.color)
                    .frame(width: 3)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.summary).font(.caption.monospaced())
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
        }

        private var timeString: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f.string(from: row.timestamp)
        }
    }
}

/// Tiny flow-layout helper: lays out children left-to-right and wraps when
/// the row exceeds the available width.
private struct FlowHStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if rowWidth + s.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
