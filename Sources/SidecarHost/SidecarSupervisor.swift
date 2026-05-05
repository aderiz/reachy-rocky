import Foundation
import Telemetry

/// Owns the set of registered sidecars, manages their lifecycle, and applies
/// restart policies. M2 implementation will plug `SidecarRuntime` into the
/// `register(...)` path.
public actor SidecarSupervisor {
    public let logBus: LogBus
    private(set) var sidecars: [String: any Sidecar] = [:]

    public init(logBus: LogBus) {
        self.logBus = logBus
    }

    public func register(_ sidecar: any Sidecar) {
        sidecars[sidecar.name] = sidecar
    }

    public func sidecar(named name: String) -> (any Sidecar)? {
        sidecars[name]
    }

    public func startAll() async throws {
        for sidecar in sidecars.values {
            try await sidecar.start()
        }
    }

    public func stopAll() async {
        for sidecar in sidecars.values {
            await sidecar.stop()
        }
    }
}
