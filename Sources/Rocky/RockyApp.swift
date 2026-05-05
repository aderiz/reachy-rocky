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

        MenuBarExtra("Rocky", systemImage: "circle.dotted") {
            MenuBarStatusView()
                .environment(services)
        }
        .menuBarExtraStyle(.window)
    }
}
