import SwiftUI

/// Unified container for every dashboard card. Establishes the chrome
/// (radius, padding, material, title weight, divider rhythm) so the cards
/// stop looking like seven independent rectangles.
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
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 16, x: 0, y: 6)
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
