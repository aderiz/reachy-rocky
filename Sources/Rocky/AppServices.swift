import Foundation
import Observation
import RobotLink
import RockyKit
import SidecarHost
import Telemetry

/// One owner for every long-lived service Rocky uses. Injected via `.environment(...)`.
/// Concrete services are wired in M1+; this skeleton holds the references that
/// the dashboard cards need to render their connection / state badges.
@Observable
@MainActor
final class AppServices {
    let logBus: LogBus
    let robotEndpoint: RobotEndpoint
    let robotLink: RobotLinkClient
    let supervisor: SidecarSupervisor

    /// Most recent reachability check for the daemon. Driven by `HealthChecker`
    /// (M1+). Default `unknown` so the UI doesn't lie until we actually check.
    var daemonReachability: Reachability = .unknown
    var lastDaemonStatus: RobotLinkClient.DaemonStatus?
    var lastRobotState: RobotState?

    enum Reachability: Sendable, Equatable {
        case unknown, online, offline(reason: String)
    }

    init(endpoint: RobotEndpoint = RobotEndpoint()) {
        let bus = LogBus()
        self.logBus = bus
        self.robotEndpoint = endpoint
        self.robotLink = RobotLinkClient(endpoint: endpoint, logBus: bus)
        self.supervisor = SidecarSupervisor(logBus: bus)
    }
}
