import SwiftUI
import Telemetry

/// Inspector → Raw. The firehose, for engineer + post-mortem use.
///
/// Per `docs/concepts/cockpit-design.md` §5: the moment feed in the
/// Activity tab is the daily surface; Raw is the un-coalesced
/// underlying stream. Off by default — a toggle reveals it. Filter
/// chips collapse into a `Menu` so the chrome fits a 320pt column.
///
/// Subscribed to `LogBus` only when active. When the user toggles off,
/// the subscription is cancelled and the buffer stays put for review.
struct LogsView: View {
    @Environment(AppServices.self) private var services
    @State private var rows: [Row] = []
    @State private var filter: String = ""
    @State private var paused: Bool = false
    @State private var enabled: Bool = false
    @State private var showCategories: Set<Category> = Set(Category.allCases)
    @State private var streamTask: Task<Void, Never>?

    private let capacity = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            if !enabled {
                offByDefaultCallout
            } else {
                densitySparkline
                controlsRow
                searchField
                Divider()
                streamView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: enabled) { _, on in
            if on { startStreaming() } else { stopStreaming() }
        }
    }

    // MARK: - Density sparkline

    /// Last-30-seconds traffic. Each cell = one second; height is the
    /// event count in that second normalised to the 30-second peak.
    /// Lets engineers see traffic spikes at a glance instead of
    /// reading row timestamps to figure out "did llm chunks just
    /// burst?".
    private var densitySparkline: some View {
        let bins = SecondBucket.compute(from: rows)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LAST 30 SEC")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(bins.totalCount) events")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(bins.bins) { bin in
                    SecondBar(bin: bin, peak: bins.peak)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 24)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Raw events", systemImage: "doc.plaintext")
                .font(.headline)
            Spacer()
            Toggle(isOn: $enabled) {
                Text(enabled ? "On" : "Off")
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Subscribe to LogBus and tail every event into the table below.")
        }
    }

    private var offByDefaultCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Raw events are off by default.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Most diagnostic answers are in the Activity tab — moments at human cadence with the same source data, coalesced. Use Raw for engineer-level inspection: motor commands, llm chunks, daemon heartbeats, sidecar logs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 6) {
            Button {
                paused.toggle()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(paused ? "Resume the stream" : "Pause the stream")

            Button {
                rows.removeAll()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Clear the buffer")

            categoryMenu

            Spacer()

            Text("\(filteredRows.count) of \(rows.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(Category.allCases) { cat in
                Toggle(cat.label, isOn: Binding(
                    get: { showCategories.contains(cat) },
                    set: { on in
                        if on { showCategories.insert(cat) }
                        else  { showCategories.remove(cat) }
                    }
                ))
            }
            Divider()
            Button("All on") { showCategories = Set(Category.allCases) }
            Button("All off") { showCategories = [] }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search events", text: $filter)
                .textFieldStyle(.plain)
                .font(.callout)
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var streamView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredRows) { row in
                        RowView(row: row).id(row.id)
                        if row.id != filteredRows.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
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

    // MARK: - Stream lifecycle

    private func startStreaming() {
        streamTask?.cancel()
        let bus = services.logBus
        streamTask = Task {
            for await event in await bus.subscribe() {
                if Task.isCancelled { return }
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

    private func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Categories

    enum Category: Sendable, Hashable, Identifiable, CaseIterable {
        case motor, vision, voice, brain, sidecar, link, error
        var id: Self { self }
        var label: String {
            switch self {
            case .motor:   "Motor"
            case .vision:  "Vision"
            case .voice:   "Voice"
            case .brain:   "Brain"
            case .sidecar: "Sidecar"
            case .link:    "Link"
            case .error:   "Error"
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

    // MARK: - Row

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
            case .addressFilterAccept(let text, let score, let reasons):
                return (.voice,
                        String(format: "addressed (%.2f) [%@]", score,
                               reasons.joined(separator: ", ")),
                        text)
            case .addressFilterDrop(let text, let score, let reasons):
                return (.voice,
                        String(format: "ignored (%.2f) [%@]", score,
                               reasons.joined(separator: ", ")),
                        text)
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
            case .brainResponse(let firstChunkMs, let totalMs):
                let tft = firstChunkMs.map { String(format: "TFT %.0fms ", $0) } ?? ""
                return (.brain,
                        String(format: "brain response %@total %.0fms", tft, totalMs),
                        "")
            case .audioPlaybackStarted(let filename, let sinceMs):
                return (.voice,
                        String(format: "audio playback started (+%.0f ms): %@",
                               sinceMs, filename),
                        "")
            case .turnProfile(let summary, let fields):
                let f = fields.isEmpty ? "" : "  " + fields
                    .sorted { $0.key < $1.key }
                    .map { "\($0)=\($1)" }
                    .joined(separator: " ")
                return (.brain, "PROFILE \(summary)", f)
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

    // MARK: - Second-bucket model + bar

    private struct SecondBucket: Identifiable {
        let id: Int
        let count: Int

        static func compute(from rows: [Row]) -> (bins: [SecondBucket], peak: Int, totalCount: Int) {
            let now = Date()
            var counts = [Int: Int](minimumCapacity: 30)
            for r in rows {
                let dt = now.timeIntervalSince(r.timestamp)
                let secAgo = Int(dt)
                guard secAgo >= 0 && secAgo < 30 else { continue }
                counts[secAgo, default: 0] += 1
            }
            let peak = counts.values.max() ?? 0
            // Oldest left, newest right.
            let bins = (0..<30).reversed().map { idx in
                SecondBucket(id: idx, count: counts[idx] ?? 0)
            }
            let total = counts.values.reduce(0, +)
            return (bins, peak, total)
        }
    }

    private struct SecondBar: View {
        let bin: SecondBucket
        let peak: Int

        var body: some View {
            GeometryReader { geo in
                let h = geo.size.height
                let normalized: CGFloat = peak > 0
                    ? CGFloat(bin.count) / CGFloat(peak)
                    : 0
                let height = max(2, h * normalized)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(bin.count > 0
                              ? AnyShapeStyle(.tint)
                              : AnyShapeStyle(.tertiary))
                        .frame(height: height)
                }
            }
            .help("\(bin.id)s ago — \(bin.count) event\(bin.count == 1 ? "" : "s")")
        }
    }

    private struct RowView: View {
        let row: Row

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(row.category.color)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(timeString)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        Text(row.category.label.lowercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(row.category.color)
                    }
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contextMenu {
                Button("Copy summary") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.summary, forType: .string)
                }
                if !row.detail.isEmpty {
                    Button("Copy detail") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.detail, forType: .string)
                    }
                }
                Button("Copy as line") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        "\(timeString) [\(row.category.label.lowercased())] " +
                            row.summary +
                            (row.detail.isEmpty ? "" : "\n  \(row.detail)"),
                        forType: .string)
                }
            }
        }

        private var timeString: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f.string(from: row.timestamp)
        }
    }
}
