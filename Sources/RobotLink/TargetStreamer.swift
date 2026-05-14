import Foundation
import RockyKit
import Telemetry

/// 50 Hz target streamer. Single producer (any thread updates the latest target),
/// single consumer (the actor's tick loop POSTs `set_target`).
///
/// Pauses while the daemon reports `is_move_running` so we don't fight a
/// recorded primary move (per the wiki: `set_target_*` is silently ignored
/// while a goto is in flight).
public actor TargetStreamer {
    public enum Status: Sendable, Equatable {
        case idle, running, paused(reason: String)
    }

    private let client: MotionGuard
    private let logBus: LogBus
    private let hz: Double
    private var task: Task<Void, Never>?
    private var latest: MotionTarget?
    private(set) public var status: Status = .idle
    private(set) public var primaryMoveActive: Bool = false
    /// Consecutive failed ticks. Used to suppress the 50 Hz error
    /// spam when the bot is unreachable — we log only the FIRST
    /// failure after a successful tick, then stay silent until the
    /// next success/failure transition.
    private var consecutiveFailures: Int = 0
    /// Stashed message of the failure we last logged, so a steady
    /// stream of identical "offline" errors produces exactly one
    /// activity-feed entry per outage instead of thousands.
    private var lastLoggedErrorMessage: String?

    public init(client: MotionGuard, logBus: LogBus, hz: Double = 50) {
        self.client = client
        self.logBus = logBus
        self.hz = hz
    }

    /// Update the target consumed on the next tick. Coalesces — only the most
    /// recent target is ever sent.
    public func update(_ target: MotionTarget, source: TelemetryEvent.MotionSource = .face) {
        latest = target
        Task { await logBus.publish(.motorCommand(source: source, target: target)) }
    }

    /// Caller (e.g. WebSocket state subscriber) tells us when the daemon is
    /// playing a primary move so we hold off streaming.
    public func setPrimaryMoveActive(_ active: Bool) {
        primaryMoveActive = active
        status = active ? .paused(reason: "primary move running") : .running
    }

    public func start() {
        guard task == nil else { return }
        status = .running
        let periodNs = UInt64(1_000_000_000 / hz)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                let started = ContinuousClock.now
                await self?.tick()
                // When the bot is offline (consecutive failures
                // climbing), back off from 50 Hz so we're not
                // hammering the OS with doomed requests AND so the
                // tick task doesn't burn a core retrying. The
                // back-off scales: < 10 failures = normal cadence,
                // 10-50 = ~5 Hz, > 50 = ~1 Hz. As soon as a tick
                // succeeds, consecutiveFailures resets and we
                // return to 50 Hz.
                let backoff = await self?.backoffNanos(period: periodNs) ?? periodNs
                let elapsed = ContinuousClock.now - started
                let remaining = Int64(backoff) - Int64(elapsed.components.attoseconds / 1_000_000_000) - Int64(elapsed.components.seconds * 1_000_000_000)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining))
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        status = .idle
    }

    private func backoffNanos(period: UInt64) -> UInt64 {
        switch consecutiveFailures {
        case ..<10:  return period               // 50 Hz, normal
        case 10..<50: return 200_000_000          // 5 Hz, offline-ish
        default:     return 1_000_000_000         // 1 Hz, deep outage
        }
    }

    private func tick() async {
        guard !primaryMoveActive, let target = latest else { return }
        do {
            try await client.setTarget(target)
            // Successful tick — clear failure state and log the
            // recovery if we were tracking an outage.
            if consecutiveFailures > 0 {
                let failed = consecutiveFailures
                consecutiveFailures = 0
                lastLoggedErrorMessage = nil
                await logBus.publish(.sidecarLog(
                    sidecar: "TargetStreamer",
                    level: .info,
                    message: "set_target recovered after \(failed) failures",
                    fields: [:]
                ))
            }
        } catch {
            consecutiveFailures += 1
            let msg = "\(error)"
            // Coalesce: only emit an Activity row when the error
            // CHANGES (e.g. offline → different transport error) or
            // on the FIRST failure of an outage. The 50 Hz stream
            // used to fire `transport(...offline)` once per tick →
            // hundreds of identical Activity rows per second.
            if lastLoggedErrorMessage != msg {
                lastLoggedErrorMessage = msg
                await logBus.publish(.error(
                    scope: "TargetStreamer",
                    message: msg,
                    recoverable: true
                ))
            }
        }
    }
}
