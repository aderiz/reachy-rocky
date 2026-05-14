import SwiftUI
import Telemetry

/// Inspector → Profile. Per-turn latency waterfalls + rolling aggregates.
///
/// Each row is a horizontal stacked bar (the "waterfall") whose segments
/// are proportional to each stage's share of the user-perceived response
/// time (STT-final → first audio on robot). Click to expand a row for
/// numeric per-stage values.
///
/// Visible signals:
///   - `audioFirstMs` — when Rocky started making any sound (preamble
///     OR direct answer). The headline "latency" number per row.
///   - `audioLastMs` (when `audioCount > 1`) — when the *answer* actually
///     started. Reveals preamble-doubling cost.
///   - `brainRounds` — flagged when >1 (means the brain made multiple
///     tool-bearing roundtrips: a major latency contributor).
struct ProfileTab: View {
    @Environment(AppServices.self) private var services
    @State private var profiles: [TurnProfile] = []
    @State private var expanded: UUID? = nil
    @State private var subscriberTask: Task<Void, Never>? = nil
    @State private var showCopyConfirm: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            if !services.settings.profilingEnabled {
                disabledHint
            } else if profiles.isEmpty {
                emptyHint
            } else {
                aggregateCard
                Divider()
                turnList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { startSubscription() }
        .onDisappear { subscriberTask?.cancel() }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Profile", systemImage: "speedometer")
                .font(.headline)
            Spacer()
            if !profiles.isEmpty {
                Button { copyCSV() } label: {
                    Label(showCopyConfirm ? "Copied" : "CSV",
                          systemImage: showCopyConfirm
                            ? "checkmark.circle.fill"
                            : "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy all profiles as CSV to clipboard.")
                Button(role: .destructive) {
                    Task { await services.profileStore.clear() }
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Clear the profile history.")
            }
            Toggle(isOn: Binding(
                get: { services.settings.profilingEnabled },
                set: { newValue in
                    services.settings.profilingEnabled = newValue
                    Task { await services.applySettings() }
                }
            )) { Text("On") }
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help("Profiling mode — captures end-to-end stage timings per turn.")
        }
    }

    private var disabledHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profiling is off.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Flip the switch above to start capturing per-turn timings. Each completed turn appears here as a stacked-bar waterfall.")
                .font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profiling is on. No turns captured yet.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Speak to Rocky (or send a chat message). When STT finalises, a turn opens; when Rocky's audio lands on the robot, the row updates. Idle turns close after 30 s.")
                .font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Aggregates

    private var aggregateCard: some View {
        let agg = ProfileStore.aggregates(of: profiles)
        return VStack(alignment: .leading, spacing: 6) {
            Text("ROLLING".uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                stat("p50 1st-audio", value: msString(agg.p50AudioFirstMs))
                stat("p95 1st-audio", value: msString(agg.p95AudioFirstMs))
                stat("p50 answer", value: msString(agg.p50AudioLastMs))
                stat("brain p50", value: msString(agg.p50BrainTotalMs))
                Spacer()
                Text("\(agg.count) complete")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Turn list

    private var turnList: some View {
        VStack(spacing: 0) {
            ForEach(profiles.reversed()) { p in
                ProfileRow(profile: p, expanded: expanded == p.id)
                    .onTapGesture {
                        expanded = expanded == p.id ? nil : p.id
                    }
                if p.id != profiles.first?.id { Divider() }
            }
        }
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Stream

    private func startSubscription() {
        subscriberTask?.cancel()
        let store = services.profileStore
        subscriberTask = Task {
            for await snapshot in await store.subscribe() {
                await MainActor.run { self.profiles = snapshot }
            }
        }
    }

    private func msString(_ ms: Double?) -> String {
        guard let v = ms else { return "—" }
        if v >= 1000 { return String(format: "%.2f s", v / 1000) }
        return String(format: "%.0f ms", v)
    }

    // MARK: - CSV

    private func copyCSV() {
        let header = "timestamp,outcome,audio_first_ms,audio_last_ms,audio_count,stt_ms,stt_to_addr_ms,brain_rounds,brain_first_chunk_ms,brain_total_ms,say_first_synth_ms,say_upload_ms,audio_s,tools"
        let rows = profiles.map { p -> String in
            func f(_ v: Double?) -> String {
                v.map { String(format: "%.0f", $0) } ?? ""
            }
            let tools = p.tools
                .map { "\($0.name):\(Int($0.latencyMs))" }
                .joined(separator: "|")
            return [
                ISO8601DateFormatter().string(from: p.timestamp),
                String(describing: p.outcome),
                f(p.audioFirstMs), f(p.audioLastMs), String(p.audioCount),
                f(p.sttMs), f(p.sttToAddrMs),
                String(p.brainRounds),
                f(p.brainFirstChunkMs), f(p.brainTotalMs),
                f(p.sayFirstSynthMs), f(p.sayUploadMs),
                p.audioDurationS.map { String(format: "%.1f", $0) } ?? "",
                tools
            ].joined(separator: ",")
        }
        let csv = ([header] + rows).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(csv, forType: .string)
        showCopyConfirm = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { showCopyConfirm = false }
        }
    }
}

// MARK: - Row

private struct ProfileRow: View {
    let profile: TurnProfile
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(timeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text(totalLabel)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .frame(width: 72, alignment: .leading)
                Waterfall(profile: profile)
                    .frame(height: 14)
                outcomeChip
            }
            if profile.audioCount > 1, let last = profile.audioLastMs {
                Text(String(format: "preamble fired — answer started at %.0f ms (×%d audio events)",
                            last, profile.audioCount))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
                    .padding(.leading, 142)
            }
            if profile.brainRounds > 1 {
                Text("brain made \(profile.brainRounds) rounds — likely a preamble + tool + answer pattern")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.leading, 142)
            }
            if expanded { detail }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.12), value: expanded)
    }

    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: profile.timestamp)
    }

    private var totalLabel: String {
        guard let ms = profile.audioFirstMs else { return "—" }
        if ms >= 1000 { return String(format: "%.2f s", ms / 1000) }
        return String(format: "%.0f ms", ms)
    }

    @ViewBuilder
    private var outcomeChip: some View {
        switch profile.outcome {
        case .complete:
            EmptyView()
        case .addressDrop:
            chip("dropped", color: .orange)
        case .notDispatched:
            chip("no reply", color: .gray)
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(stageRows, id: \.label) { row in
                HStack(alignment: .firstTextBaseline) {
                    Circle().fill(row.color).frame(width: 8, height: 8)
                    Text(row.label)
                        .font(.caption)
                        .frame(width: 130, alignment: .leading)
                    Text(row.formatted)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if profile.sayFirstSynthMs != nil
                || profile.sayUploadMs != nil
                || profile.audioDurationS != nil
            {
                let synth = profile.sayFirstSynthMs.map {
                    String(format: "synth %.0f ms", $0) } ?? ""
                let upload = profile.sayUploadMs.map {
                    String(format: "upload %.0f ms", $0) } ?? ""
                let audio = profile.audioDurationS.map {
                    String(format: "audio %.1f s", $0) } ?? ""
                let bits = [synth, upload, audio].filter { !$0.isEmpty }
                Text("  " + bits.joined(separator: " · "))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 16)
            }
            if !profile.tools.isEmpty {
                Text("  tools: " + profile.tools
                    .map { String(format: "%@ %.0f ms", $0.name, $0.latencyMs) }
                    .joined(separator: " · "))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 16)
            }
        }
        .padding(.leading, 140)
        .padding(.top, 4)
    }

    private var stageRows: [ProfileStage] { ProfileRow.stages(for: profile) }
    fileprivate static func stages(for p: TurnProfile) -> [ProfileStage] {
        var out: [ProfileStage] = []
        if let v = p.sttMs       { out.append(.init(label: "STT",        ms: v, color: .green)) }
        if let v = p.sttToAddrMs { out.append(.init(label: "Dispatch",   ms: v, color: .yellow)) }
        if let v = p.brainTotalMs {
            out.append(.init(label: "Brain", ms: v, color: .blue))
        }
        // Surface each tool as its own segment so the user can see
        // which tool was the dominant cost (search_web, say, express).
        for t in p.tools {
            out.append(.init(label: t.name, ms: t.latencyMs, color: color(for: t.name)))
        }
        return out
    }

    fileprivate static func color(for tool: String) -> Color {
        switch tool {
        case "say":         return .orange
        case "express":     return .pink
        case "play_emotion":return .pink
        case "search_web":  return .purple
        case "recall_memory":return .teal
        case "remember":    return .teal
        case "go_home":     return .gray
        case "get_weather", "get_current_time", "read_calendar":
            return .indigo
        default:            return .gray
        }
    }
}

fileprivate struct ProfileStage: Hashable {
    let label: String
    let ms: Double
    let color: Color
    var formatted: String {
        ms >= 1000 ? String(format: "%.2f s", ms / 1000)
                   : String(format: "%.0f ms", ms)
    }
}

// MARK: - Waterfall

private struct Waterfall: View {
    let profile: TurnProfile

    var body: some View {
        GeometryReader { geo in
            let stages = ProfileRow.stages(for: profile)
            let totalMs = max(1, stages.map(\.ms).reduce(0, +))
            HStack(spacing: 0) {
                ForEach(stages, id: \.label) { stage in
                    Rectangle()
                        .fill(stage.color)
                        .frame(width: geo.size.width * (stage.ms / totalMs))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }
}
