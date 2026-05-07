import SwiftUI
import AppKit
import RobotLink
import RockyKit
import SidecarHost
import Telemetry

@main
struct RockyApp: App {
    @State private var services = AppServices()

    init() {
        // Without this, a SwiftPM executable launched directly (e.g. ⌘R
        // in Xcode on Package.swift, or `swift run`) defaults to the
        // `.prohibited` activation policy because there's no Info.plist
        // bundle to define one. In that mode AppKit doesn't make the
        // SwiftUI window key, and TextFields silently refuse keyboard
        // input. `build/Rocky.app` (from scripts/build-app.sh) ships an
        // Info.plist so this isn't strictly required for the bundled
        // app, but doing it unconditionally lets either launch path work
        // identically — useful while iterating in Xcode's debugger.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

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
        case .sleeping:   "moon.fill"
        case .waking:     "sun.max"
        case .idle:       "circle.fill"
        case .listening:  "ear"
        case .thinking:   "circle.dotted"
        case .speaking:   "waveform"
        case .error:      "exclamationmark.circle.fill"
        }
        Image(systemName: symbol)
    }
}
