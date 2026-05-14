import Foundation
import RockyKit
import Telemetry

/// Single chokepoint for every motion command Rocky issues to the daemon.
///
/// Every `setTarget`, `goto`, and `playRecordedMove` call MUST go through
/// this guard rather than calling `RobotLinkClient` directly. The guard
/// enforces:
///
/// 1. **Slew-rate limit on `setTarget`** — caps the per-tick change
///    in each joint's commanded target so abrupt jumps in `latest`
///    (face tracker pivoting between subjects, look-at-object firing
///    while the streamer's still pushing the previous pose, etc.)
///    don't translate into a hardware-limited motor slew that reads
///    as a jerk.
///
/// 2. **Velocity clamp on `goto`** — for *all* joints (head, body,
///    antennas). The old `safeGotoDuration` only considered head
///    pose. A big body-yaw delta with a short requested duration
///    could exceed the safe velocity ceiling silently.
///
/// 3. **Duration floor on `goto`** — every goto gets at least
///    `Config.minGotoDurationS` (default 0.4 s). Prevents a
///    callsite from issuing a 50 ms "snap" move.
///
/// 4. **Single-in-flight `goto`** — overlapping gotos cancel each
///    other on the daemon side and produce visible jerks at the
///    transition. The guard serialises gotos so the second waits
///    for the first.
///
/// 5. **Shelf-safe recorded-move allowlist** — `playRecordedMove`
///    only accepts moves in `Config.shelfSafeMoves` unless the
///    explicit `force: true` flag is set. The Pollen emotions
///    library has moves authored for floor-mounted bots that have
///    knocked Rocky off the desk shelf; this gate makes that
///    impossible by default.
///
/// The guard is an actor so multiple concurrent callers serialise
/// through its state (`lastSentTarget`, `inflightGoto`).
public actor MotionGuard {
    public struct Config: Sendable {
        /// Max change in any commanded joint per `setTarget` call.
        /// At 50 Hz, 0.05 rad ≈ 2.9°/tick ≈ 143°/s. Below the
        /// damper's max output speed (1.2 rad/s ≈ 69°/s), so smooth
        /// damped inputs pass through unchanged; sudden jumps get
        /// flattened into a slew.
        public var maxSetTargetSlewRad: Double = 0.05

        /// Goto duration floor. 0.4 s reads as "deliberate but
        /// responsive"; anything shorter snaps and looks frightening.
        public var minGotoDurationS: TimeInterval = 0.4

        /// Max joint velocity for goto duration stretching. Same as
        /// the existing global ceiling so behaviour is consistent.
        public var maxGotoVelocityRadPerS: Double = 1.5

        /// Max difference between head_yaw and body_yaw, in radians.
        /// Pollen documents this as a HARDWARE safety constraint
        /// (anti-collision between the head and body) at 65°. The
        /// daemon clamps to "the closest valid position" silently
        /// when you exceed it — meaning the actual head or body
        /// ends up somewhere other than commanded, which the brain's
        /// next round won't be expecting. Enforcing it here makes
        /// the failure explicit: the goto either targets a feasible
        /// pose or it gets reshaped before send.
        public var maxHeadBodyYawDeltaRad: Double = 65.0 * .pi / 180.0

        /// Recorded moves that have been audited as safe on a
        /// desk-shelf mount (slow, low head excursion, no body
        /// rotation extremes). `playRecordedMove` rejects anything
        /// outside this set unless `force: true`.
        ///
        /// The dance/rage moves are deliberately excluded — they
        /// were the source of the 2026-05-13 shelf incident.
        public var shelfSafeMoves: Set<String> = [
            "amazed1", "attentive1", "calming1", "cheerful1",
            "curious1", "grateful1", "helpful1", "indifferent1",
            "inquiring1", "no1", "no_sad1", "proud1", "relief1",
            "sad1", "serenity1", "shy1", "thoughtful1", "tired1",
            "understanding1", "welcoming1", "yes1", "yes_sad1",
            "downcast1", "lonely1", "loving1", "uncertain1",
        ]

        public init() {}
    }

    private let client: RobotLinkClient
    private let logBus: LogBus
    private(set) public var config: Config

    private var lastSentTarget: MotionTarget?
    private var inflightGoto: Task<Void, Error>?

    public init(
        client: RobotLinkClient,
        logBus: LogBus,
        config: Config = .init()
    ) {
        self.client = client
        self.logBus = logBus
        self.config = config
    }

    public func setConfig(_ config: Config) { self.config = config }

    // MARK: - setTarget (slew-rate limited)

    public func setTarget(_ target: MotionTarget) async throws {
        let limited = slewLimit(target, against: lastSentTarget)
        lastSentTarget = limited
        try await client.setTarget(limited)
    }

    private func slewLimit(
        _ target: MotionTarget, against prev: MotionTarget?
    ) -> MotionTarget {
        guard let prev else { return target }
        let maxSlew = config.maxSetTargetSlewRad
        var limited = target
        if let newHead = target.headPose, let prevHead = prev.headPose {
            limited.headPose = RPYPose(
                roll: clampDelta(newHead.roll, prev: prevHead.roll, maxDelta: maxSlew),
                pitch: clampDelta(newHead.pitch, prev: prevHead.pitch, maxDelta: maxSlew),
                yaw: clampDelta(newHead.yaw, prev: prevHead.yaw, maxDelta: maxSlew)
            )
        }
        if let newAnt = target.antennas, let prevAnt = prev.antennas {
            limited.antennas = Antennas(
                rightRad: clampDelta(newAnt.right, prev: prevAnt.right, maxDelta: maxSlew),
                leftRad: clampDelta(newAnt.left, prev: prevAnt.left, maxDelta: maxSlew)
            )
        }
        if let newBody = target.bodyYaw, let prevBody = prev.bodyYaw {
            limited.bodyYaw = clampDelta(newBody, prev: prevBody, maxDelta: maxSlew)
        }
        return limited
    }

    private func clampDelta(_ new: Double, prev: Double, maxDelta: Double) -> Double {
        let delta = new - prev
        if abs(delta) <= maxDelta { return new }
        return prev + (delta > 0 ? maxDelta : -maxDelta)
    }

    // MARK: - goto (velocity + duration floor + single-in-flight)

    public func goto(
        headPose: RPYPose? = nil,
        antennas: Antennas? = nil,
        bodyYaw: Double? = nil,
        durationS: TimeInterval,
        interpolation: RobotLinkClient.Interpolation = .minjerk
    ) async throws {
        // Serialise with any in-flight goto so a new caller can't
        // interrupt a slow move mid-flight.
        if let pending = inflightGoto {
            _ = try? await pending.value
        }

        // Floor the requested duration.
        let floored = max(durationS, config.minGotoDurationS)

        // **Head-body yaw delta gate.** Pollen's daemon enforces a
        // 65° max between head and body yaw (anti-collision). If the
        // requested pose would exceed that, the daemon silently
        // clamps — leaving the bot somewhere other than commanded.
        // Pull the head and/or body in here so we send a feasible
        // pose that lands where the brain thinks it should.
        let reshapedHead: RPYPose?
        let reshapedBody: Double?
        (reshapedHead, reshapedBody) = await reshapeForYawDelta(
            headPose: headPose, bodyYaw: bodyYaw
        )

        // Compute a safe duration that respects velocity across ALL
        // joints (not just head, which is all RobotLinkClient.goto
        // currently checks).
        let safe = await safeDuration(
            headPose: reshapedHead, antennas: antennas, bodyYaw: reshapedBody,
            requested: floored
        )
        if safe > floored {
            await logBus.publish(.sidecarLog(
                sidecar: "motion-guard",
                level: .info,
                message: String(
                    format: "goto duration stretched %.2fs → %.2fs (velocity cap)",
                    floored, safe
                ),
                fields: [:]
            ))
        }

        let task = Task { [client] in
            try await client.goto(
                headPose: reshapedHead, antennas: antennas, bodyYaw: reshapedBody,
                durationS: safe, interpolation: interpolation
            )
        }
        inflightGoto = task
        defer { inflightGoto = nil }

        try await task.value

        // Sync lastSentTarget so subsequent setTarget slew limiting
        // starts from where the goto actually parked the bot. Use
        // the reshaped poses (post yaw-delta enforcement) since that
        // is what the daemon actually received.
        if let h = reshapedHead {
            lastSentTarget = MotionTarget(
                headPose: h, antennas: antennas ?? lastSentTarget?.antennas,
                bodyYaw: reshapedBody ?? lastSentTarget?.bodyYaw
            )
        }
    }

    /// Enforces Pollen's 65° head-body yaw delta limit. If the requested
    /// (or current-if-not-requested) head and body yaws exceed that
    /// difference, pulls them together so the difference equals the
    /// cap. Splits the correction 50/50 across the two joints; if only
    /// one of head/body is being commanded, the other stays put and
    /// the commanded one absorbs the full correction.
    private func reshapeForYawDelta(
        headPose: RPYPose?, bodyYaw: Double?
    ) async -> (RPYPose?, Double?) {
        // Need both current values to reason about the delta.
        let current: RobotState? = try? await client.fullState()
        let curHeadYaw = current?.headPose.yaw ?? 0
        let curBodyYaw = current?.bodyYaw ?? 0

        let targetHeadYaw = headPose?.yaw ?? curHeadYaw
        let targetBodyYaw = bodyYaw ?? curBodyYaw
        let delta = targetHeadYaw - targetBodyYaw
        let maxDelta = config.maxHeadBodyYawDeltaRad

        if abs(delta) <= maxDelta {
            return (headPose, bodyYaw)
        }

        // Exceeded — pull both toward each other so the new delta
        // equals the cap. If only head OR only body was commanded,
        // the un-commanded one stays at its current value.
        let excess = abs(delta) - maxDelta
        let direction: Double = delta > 0 ? 1 : -1
        var newHeadYaw = targetHeadYaw
        var newBodyYaw = targetBodyYaw
        if headPose != nil && bodyYaw != nil {
            newHeadYaw -= direction * excess / 2
            newBodyYaw += direction * excess / 2
        } else if headPose != nil {
            newHeadYaw -= direction * excess
        } else if bodyYaw != nil {
            newBodyYaw += direction * excess
        }

        await logBus.publish(.sidecarLog(
            sidecar: "motion-guard",
            level: .warn,
            message: String(
                format: "yaw-delta limit: head %.1f° + body %.1f° (Δ %.1f°) → head %.1f° + body %.1f° (Δ %.1f°)",
                targetHeadYaw * 180 / .pi, targetBodyYaw * 180 / .pi,
                delta * 180 / .pi,
                newHeadYaw * 180 / .pi, newBodyYaw * 180 / .pi,
                (newHeadYaw - newBodyYaw) * 180 / .pi
            ),
            fields: [:]
        ))

        let reshapedHead: RPYPose? = headPose.map {
            RPYPose(roll: $0.roll, pitch: $0.pitch, yaw: newHeadYaw)
        }
        let reshapedBody: Double? = bodyYaw.map { _ in newBodyYaw }
        return (reshapedHead, reshapedBody)
    }

    private func safeDuration(
        headPose: RPYPose?, antennas: Antennas?, bodyYaw: Double?,
        requested: TimeInterval
    ) async -> TimeInterval {
        let current: RobotState?
        do { current = try await client.fullState() }
        catch { current = nil }

        var maxDelta: Double = 0
        if let h = headPose, let cur = current?.headPose {
            maxDelta = max(maxDelta, abs(h.roll - cur.roll))
            maxDelta = max(maxDelta, abs(h.pitch - cur.pitch))
            maxDelta = max(maxDelta, abs(h.yaw - cur.yaw))
        }
        if let b = bodyYaw, let curBody = current?.bodyYaw {
            maxDelta = max(maxDelta, abs(b - curBody))
        }
        if let a = antennas, let curAnt = current?.antennasPosition {
            maxDelta = max(maxDelta, abs(a.right - curAnt.right))
            maxDelta = max(maxDelta, abs(a.left - curAnt.left))
        }
        let minSafe = maxDelta / config.maxGotoVelocityRadPerS
        return max(requested, minSafe)
    }

    // MARK: - Recorded moves (shelf-safe allowlist)

    public func playRecordedMove(
        dataset: String,
        move: String,
        force: Bool = false
    ) async throws {
        if !force, !config.shelfSafeMoves.contains(move) {
            await logBus.publish(.sidecarLog(
                sidecar: "motion-guard",
                level: .warn,
                message: "blocked recorded move '\(move)' — not in shelf-safe allowlist",
                fields: ["dataset": dataset, "move": move]
            ))
            throw MotionGuardError.notShelfSafe(move: move)
        }
        try await client.playRecordedMove(dataset: dataset, move: move)
    }

    // MARK: - Pass-throughs (non-motion calls keep raw access)

    /// Read-only state passthrough. The guard doesn't need to gate
    /// reads, and callers (face tracker, state subscriber) need them
    /// at high frequency.
    public func fullState() async throws -> RobotState {
        try await client.fullState()
    }

    public func stopMove() async throws {
        try await client.stopMove()
    }

    public func setMotorMode(_ mode: MotorMode) async throws {
        try await client.setMotorMode(mode)
    }

    /// `goToSleep` is the daemon's `goto_sleep` recorded move. It's
    /// authored to land in a controlled slump, so it bypasses the
    /// shelf-safe allowlist (it IS the safe pose). Disables motors
    /// at the end.
    public func goToSleep() async throws {
        try await client.goToSleep()
    }

    /// `wakeUp` is the daemon's wake sequence: pre-seed → enable
    /// motors → 2 s minjerk goto to neutral. Same justification as
    /// `goToSleep` — controlled, intentional, by design safe.
    public func wakeUp() async throws {
        try await client.wakeUp()
    }
}

public enum MotionGuardError: Error, LocalizedError {
    case notShelfSafe(move: String)

    public var errorDescription: String? {
        switch self {
        case .notShelfSafe(let move):
            return "recorded move '\(move)' is not on the shelf-safe allowlist; use force=true to override (CHECK SHELF FIRST)"
        }
    }
}
