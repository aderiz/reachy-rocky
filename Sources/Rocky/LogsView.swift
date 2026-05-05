import SwiftUI
import Telemetry

/// Tails the LogBus into an in-memory ring buffer (last N events) and
/// renders a filterable, color-coded list. Surfaces the same events that
/// power the dashboard cards, but flat — handy when something doesn't
/// look right and you want to know why.
struct LogsView: View {
    @Environment(AppServices.self) private var services
    @State private var rows: [Row] = []
    @State private var filter: String = ""
    @State private var paused: Bool = false
    @State private var showCategories: Set<Category> = Set(Category.allCases)

    private let capacity = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.plaintext")
                Text("Logs").font(.headline)
                Spacer()
                Pill(text: "\(filteredRows.count) / \(rows.count)", tint: .secondary)
                Toggle(isOn: $paused) { Image(systemName: paused ? "play.fill" : "pause.fill") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help(paused ? "Resume tail" : "Pause tail")
                Button {
                    rows.removeAll()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Clear")
            }

            HStack(spacing: 6) {
                ForEach(Category.allCases) { cat in
                    Toggle(isOn: Binding(
                        get: { showCategories.contains(cat) },
                        set: { isOn in
                            if isOn { showCategories.insert(cat) }
                            else    { showCategories.remove(cat) }
                        }
                    )) {
                        Text(cat.label).font(.caption)
                    }
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .tint(cat.color)
                }
                Spacer()
                TextField("filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredRows) { row in
                            RowView(row: row).id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
                .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: filteredRows.last?.id) { _, newId in
                    guard !paused, let id = newId else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
        .padding(16)
        .task {
            // Subscribe to the LogBus once, push events into the ring buffer.
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
                        String(format: "tool %@ -> %dms", name, Int(ms)),
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
            HStack(alignment: .top, spacing: 8) {
                Text(timeString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Pill(text: row.category.label, tint: row.category.color)
                    .frame(width: 56)
                VStack(alignment: .leading, spacing: 0) {
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
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
        }

        private var timeString: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f.string(from: row.timestamp)
        }
    }

    private struct Pill: View {
        let text: String
        let tint: Color
        var body: some View {
            HStack(spacing: 3) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(text).font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }
}
