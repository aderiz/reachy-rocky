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
                let elapsed = ContinuousClock.now - started
                let remaining = Int64(periodNs) - Int64(elapsed.components.attoseconds / 1_000_000_000) - Int64(elapsed.components.seconds * 1_000_000_000)
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

    private func tick() async {
        guard !primaryMoveActive, let target = latest else { return }
        do {
            try await client.setTarget(target)
        } catch {
            await logBus.publish(.error(scope: "TargetStreamer", message: "\(error)", recoverable: true))
        }
    }
}
