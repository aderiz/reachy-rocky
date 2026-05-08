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
            filterPills
            Divider()
            momentList
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
