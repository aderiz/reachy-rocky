import SwiftUI

/// MenuBarExtra content. Five visual states arrive in M7; this is the scaffold
/// (calm tech: idle dot, click to reveal a small panel).
struct MenuBarStatusView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.gray)
                    .font(.caption)
                Text("Rocky")
                    .font(.headline)
                Spacer()
            }

            Divider()

            Button("Open Dashboard") { /* M7 */ }
            Button("Mute Mic")       { /* M4 */ }
            Button("Mute Voice")     { /* M5 */ }
            Button("Pause Tracking") { /* M3 */ }

            Divider()

            Button("Quit Rocky") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}
