import SwiftUI

/// Hero card placeholder. Real implementation arrives in M7 (UX pass) — but it
/// needs to exist now so the rest of the dashboard layout has somewhere to dock.
struct HeroCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Circle()
                .strokeBorder(.tint, lineWidth: 2)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 28, weight: .light))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Rocky")
                    .font(.title2.weight(.semibold))
                Text("Idle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
