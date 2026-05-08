import SwiftUI
import Telemetry

/// Activity tab — the human-cadence successor to `LogsView`. Per
/// `docs/concepts/cockpit-design.md` §5.3, this tab renders moments
/// from `MomentFeed`'s ring buffer with category filter pills and
/// click-to-expand source detail.
///
/// The firehose `LogsView` lives behind the Inspector's "Raw" tab; if
/// you want to grep by event type, that's the place. Most diagnostic
/// answers come from this tab — the moments are deliberately
/// templated as one-line sentences so the user can scan them.
struct ActivityTab: View {
    @Environment(AppServices.self) private var services
    @State private var enabledCategories: Set<Moment.Category>
        = Set(Moment.Category.allCases)
    @State private var expandedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            timeline
            filterPills
            Divider()
            momentList
        }
    }

    // MARK: - Timeline density

    /// 60-minute density strip: one bar per minute, height = number of
    /// visible moments in that minute, leading-tinted by the dominant
    /// category. Answers "when has anything been happening?" at a
    /// glance — and complements the list below by giving a sense of
    /// activity rhythm the moment-by-moment view doesn't.
    private var timeline: some View {
        let buckets = ActivityBucket.compute(
            from: services.recentMoments,
            categories: enabledCategories
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LAST 60 MIN")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(buckets.totalCount) moments")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(buckets.bins) { bin in
                    BucketBar(bin: bin, peak: buckets.peak)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 36)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Activity", systemImage: "list.bullet.rectangle")
                .font(.headline)
            Spacer()
            Text("\(visibleMoments.count) of \(services.recentMoments.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Filter pills

    private var filterPills: some View {
        HStack(spacing: 6) {
            ForEach(Moment.Category.allCases, id: \.self) { cat in
                let on = enabledCategories.contains(cat)
                Button {
                    if on {
                        enabledCategories.remove(cat)
                    } else {
                        enabledCategories.insert(cat)
                    }
                } label: {
                    Text(label(cat))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(on ? AnyShapeStyle(.tint.opacity(0.18))
                                          : AnyShapeStyle(.quaternary))
                        )
                        .foregroundStyle(on ? AnyShapeStyle(.tint)
                                          : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(on ? "Hide \(label(cat).lowercased()) moments"
                          : "Show \(label(cat).lowercased()) moments")
            }
            Spacer()
        }
    }

    private func label(_ cat: Moment.Category) -> String {
        switch cat {
        case .turn:       return "Turn"
        case .vision:     return "Vision"
        case .lifecycle:  return "Lifecycle"
        case .error:      return "Error"
        case .sidecar:    return "Sidecar"
        }
    }

    // MARK: - List

    private var visibleMoments: [Moment] {
        services.recentMoments.reversed().filter {
            enabledCategories.contains($0.category)
        }
    }

    @ViewBuilder
    private var momentList: some View {
        if visibleMoments.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "moon.stars")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(services.recentMoments.isEmpty
                     ? "Nothing's happened yet."
                     : "No moments match the active filters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleMoments) { moment in
                        MomentRow(moment: moment,
                                  expanded: expandedID == moment.id)
                            .onTapGesture {
                                expandedID = expandedID == moment.id
                                    ? nil : moment.id
                            }
                    }
                }
            }
        }
    }
}

// MARK: - Bucket model + bar

/// One minute's worth of moments. Used by the timeline density strip.
private struct ActivityBucket: Identifiable {
    let id: Int                 // minutes-ago index
    let count: Int
    let dominantCategory: Moment.Category?

    /// Compute 60 minute-buckets from the most-recent slice of the
    /// moment feed. Bins are filtered to the active categories so the
    /// timeline visualises *what the user is currently looking at*,
    /// not the full unfiltered firehose.
    static func compute(
        from moments: [Moment],
        categories: Set<Moment.Category>
    ) -> (bins: [ActivityBucket], peak: Int, totalCount: Int) {
        let now = Date()
        var counts = [Int: Int](minimumCapacity: 60)
        var perCategory = [Int: [Moment.Category: Int]](minimumCapacity: 60)
        for m in moments {
            guard categories.contains(m.category) else { continue }
            let dt = now.timeIntervalSince(m.timestamp)
            let minutesAgo = Int(dt / 60)
            guard minutesAgo >= 0 && minutesAgo < 60 else { continue }
            counts[minutesAgo, default: 0] += 1
            perCategory[minutesAgo, default: [:]][m.category, default: 0] += 1
        }
        let peak = counts.values.max() ?? 0
        // Bin 0 is the most-recent minute, so render right-to-left in
        // the parent's HStack reverse order: oldest left, newest right.
        let bins: [ActivityBucket] = (0..<60).reversed().map { idx in
            let count = counts[idx] ?? 0
            let dom = perCategory[idx]?
                .max(by: { $0.value < $1.value })?.key
            return ActivityBucket(id: idx,
                                   count: count,
                                   dominantCategory: dom)
        }
        let total = counts.values.reduce(0, +)
        return (bins, peak, total)
    }
}

/// Single bar in the density strip. Min-height keeps an empty bin
/// visible as a faint dot so the strip reads as a continuous
/// timeline rather than disappearing into the background.
private struct BucketBar: View {
    let bin: ActivityBucket
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
                    .fill(barTint)
                    .frame(height: height)
            }
        }
        .help(tooltip)
    }

    private var barTint: AnyShapeStyle {
        if bin.count == 0 { return AnyShapeStyle(.tertiary) }
        switch bin.dominantCategory {
        case .turn:       return AnyShapeStyle(.tint)
        case .vision:     return AnyShapeStyle(.green)
        case .lifecycle:  return AnyShapeStyle(.orange)
        case .error:      return AnyShapeStyle(.red)
        case .sidecar:    return AnyShapeStyle(.purple)
        case nil:         return AnyShapeStyle(.tertiary)
        }
    }

    private var tooltip: String {
        if bin.count == 0 { return "\(bin.id) min ago — quiet" }
        let plural = bin.count == 1 ? "moment" : "moments"
        return "\(bin.id) min ago — \(bin.count) \(plural)"
    }
}

/// One moment as a row. `.callout` text, leading SF Symbol, trailing
/// relative timestamp. Expands inline on click.
private struct MomentRow: View {
    let moment: Moment
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: moment.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(moment.sentence)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(expanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(relativeTimestamp(moment.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if expanded { detailBlock }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var detailBlock: some View {
        // Only some moments have meaningful detail beyond the sentence.
        // For now we surface the absolute timestamp and the kind name —
        // useful for cross-referencing with the Raw tab.
        VStack(alignment: .leading, spacing: 2) {
            Text(moment.timestamp.formatted(.dateTime
                .hour().minute().second().secondFraction(.fractional(3))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 26)
    }

    private func relativeTimestamp(_ date: Date) -> String {
        let dt = Date().timeIntervalSince(date)
        if dt < 1 { return "now" }
        if dt < 60 { return "\(Int(dt))s" }
        if dt < 3600 { return "\(Int(dt / 60))m" }
        return "\(Int(dt / 3600))h"
    }
}
