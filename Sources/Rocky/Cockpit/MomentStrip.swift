import SwiftUI
import Telemetry

/// MomentStrip — the cockpit's margin. Per
/// `docs/concepts/cockpit-design.md` §5.3, a slim 32pt area at the
/// bottom of the conversation column showing the *latest* moment by
/// default, expanding to four rows on hover.
///
/// New moments crossfade in over 250ms — the strip is deliberately
/// calm, never autoscrolling fast enough to feel like a stream. When
/// no moment has happened in a while, the strip dims to a single
/// "All quiet" line.
struct MomentStrip: View {
    @Environment(AppServices.self) private var services
    @State private var hovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.18), value: hovered)
    }

    @ViewBuilder
    private var content: some View {
        let recent = Array(services.recentMoments.suffix(4).reversed())
        if let latest = recent.first {
            ForEach(hovered ? Array(recent.prefix(4)) : [latest]) { moment in
                MomentStripRow(moment: moment)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        } else {
            Text("All quiet.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct MomentStripRow: View {
    let moment: Moment

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: moment.symbolName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(moment.sentence)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(relativeTimestamp(moment.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func relativeTimestamp(_ date: Date) -> String {
        let dt = Date().timeIntervalSince(date)
        if dt < 1 { return "now" }
        if dt < 60 { return "\(Int(dt))s" }
        if dt < 3600 { return "\(Int(dt / 60))m" }
        return "\(Int(dt / 3600))h"
    }
}
