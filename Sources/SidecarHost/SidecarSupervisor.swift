import Foundation
import Telemetry

/// Owns the set of registered sidecars, applies restart policies, and surfaces
/// status the dashboard mirrors. The supervisor watches each runtime's
/// `events` stream, detects `.failing`, and restarts per `restartPolicy`
/// with a per-minute circuit breaker.
public actor SidecarSupervisor {
    public let logBus: LogBus
    private var sidecars: [String: any Sidecar] = [:]
    private var watchers: [String: Task<Void, Never>] = [:]
    private let circuitCooldownS: Double = 60

    public init(logBus: LogBus) {
        self.logBus = logBus
    }

    /// Build a `SidecarRuntime` from a manifest and register it. Caller is
    /// responsible for `await supervisor.start(name:)` to actually launch.
    @discardableResult
    public func register(
        manifest: SidecarManifest,
        sidecarDir: URL,
        venvDir: URL? = nil
    ) -> any Sidecar {
        let resolvedVenv = venvDir ?? Self.defaultVenvDir(for: manifest.name)
        let resolver = ManifestPathResolver(sidecarDir: sidecarDir, venvDir: resolvedVenv)
        let runtime = SidecarRuntime(manifest: manifest, resolver: resolver, logBus: logBus)
        sidecars[runtime.name] = runtime
        watchers[runtime.name] = Task { [weak self, runtime] in
            await self?.watch(runtime)
        }
        return runtime
    }

    public func sidecar(named name: String) -> (any Sidecar)? {
        sidecars[name]
    }

    /// Start every registered sidecar. Errors propagate from the first failure.
    public func startAll() async throws {
        for sidecar in sidecars.values {
            try await sidecar.start()
        }
    }

    public func start(name: String) async throws {
        guard let s = sidecars[name] else { throw SidecarError.supervisorClosed }
        try await s.start()
    }

    public func stopAll() async {
        for sidecar in sidecars.values {
            await sidecar.stop()
        }
    }

    public func stop(name: String) async {
        await sidecars[name]?.stop()
    }

    public nonisolated static func defaultVenvDir(for name: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Rocky", isDirectory: true)
            .appendingPathComponent("sidecars", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(".venv", isDirectory: true)
    }

    // MARK: - Watcher

    private func watch(_ sidecar: any Sidecar) async {
        for await event in sidecar.events {
            switch event {
            case .state(let s):
                await logBus.publish(.sidecarState(sidecar: sidecar.name, transition: "\(s)"))
                if case .failing = s {
                    await maybeRestart(sidecar)
                }
            case .event, .log:
                continue
            }
        }
    }

    private func maybeRestart(_ sidecar: any Sidecar) async {
        let manifest = sidecar.manifest
        switch manifest.restartPolicy {
        case .never:
            return
        case .onFailure, .always:
            // Rate-limit
            if let runtime = sidecar as? SidecarRuntime {
                await runtime.markRestartAttempt()
                if await runtime.shouldCircuitBreak() {
                    await runtime.enterCircuitBreak(cooldownS: circuitCooldownS)
                    await logBus.publish(.error(
                        scope: "supervisor",
                        message: "circuit-break: \(sidecar.name) restarted too rapidly",
                        recoverable: false
                    ))
                    return
                }
            }
            // Backoff: 250ms, 500ms, 1s, 2s, 4s, capped.
            let backoff = max(0.25, min(4.0, 0.25 * pow(2.0, Double(0))))
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))

            do {
                try await sidecar.start()
                await logBus.publish(.sidecarState(
                    sidecar: sidecar.name, transition: "restarted"
                ))
            } catch {
                await logBus.publish(.error(
                    scope: "supervisor",
                    message: "restart failed: \(sidecar.name): \(error)",
                    recoverable: true
                ))
            }
        }
    }
}
