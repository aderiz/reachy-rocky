import SwiftUI
import RobotLink
import RockyKit
import SidecarHost
import Telemetry

@main
struct RockyApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup("Rocky") {
            RootView()
                .environment(services)
                .frame(minWidth: 920, minHeight: 600)
                .task { await services.start() }
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarStatusView()
                .environment(services)
        } label: {
            MenuBarLabel()
                .environment(services)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @Environment(AppServices.self) private var services
    var body: some View {
        // SF Symbol that subtly conveys the current state in the menu bar.
        let symbol: String = switch services.rockyState {
        case .idle:       "circle.fill"
        case .listening:  "ear"
        case .thinking:   "circle.dotted"
        case .speaking:   "waveform"
        case .error:      "exclamationmark.circle.fill"
        }
        Image(systemName: symbol)
    }
}
