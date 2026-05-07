import SwiftUI

/// Unified container for grouping. Per `docs/concepts/cockpit-design.md`
/// §4.3, cards are now the exception, not the rule — the cockpit's
/// stage, hearing strip, and moment feed are not cards. Cards return
/// only inside the inspector and Settings, where the grouping itself is
/// meaningful.
///
/// Chrome simplified to system materials: `.regularMaterial` with a
/// rounded clip, no shadow, no manual stroke. Materials adapt to
/// light/dark + Reduce Transparency automatically; the stacked shadows
/// the previous chrome carried fought the system materials and flattened
/// hierarchy.
struct Card<Header: View, Content: View>: View {
    let header: Header
    let content: Content

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Common card title row: icon + title + optional accessory chips on the
/// right. Keeps typography + spacing consistent across cards.
struct CardHeader<Trailing: View>: View {
    let title: String
    let icon: String
    let trailing: Trailing

    init(_ title: String, icon: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Label {
                Text(title).font(.headline.weight(.semibold))
            } icon: {
                Image(systemName: icon).foregroundStyle(.tint)
            }
            Spacer()
            trailing
        }
    }
}

/// Compact pill — single styling rule for every status/badge in the app.
struct StatusPill: View {
    let text: String
    let tint: Color
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
            } else {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(tint.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(tint.opacity(0.25), lineWidth: 1)
        )
    }
}

/// Common section title used inside cards (Voice card subsections etc.).
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}
