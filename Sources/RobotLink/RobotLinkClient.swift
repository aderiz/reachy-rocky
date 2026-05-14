import Foundation
import RockyKit
import Telemetry

/// REST client for the Reachy Mini daemon at `http://<host>:<port>/api/...`.
///
/// Endpoint paths and payload shapes follow the wiki's reference table; deltas
/// against the live `/openapi.json` are captured as ADR amendments at M1
/// kickoff (see plan §4.1).
public actor RobotLinkClient {
    public let endpoint: RobotEndpoint
    private let session: URLSession
    private let logBus: LogBus

    public init(
        endpoint: RobotEndpoint = RobotEndpoint(),
        session: URLSession = .shared,
        logBus: LogBus
    ) {
        self.endpoint = endpoint
        self.session = session
        self.logBus = logBus
    }

    // MARK: - Daemon health

    public struct DaemonStatus: Sendable, Codable {
        public let periodMs: Double?
        public let readDtMs: Double?
        public let writeDtMs: Double?
        public let raw: [String: String]?
    }

    /// `GET /api/daemon/status` — best-effort decode; raw body returned if shape is unexpected.
    public func daemonStatus() async throws -> DaemonStatus {
        let (data, status) = try await get(path: "/api/daemon/status")
        try ensureOK(status: status, body: data)
        return Self.decodeDaemonStatus(data)
    }

    // MARK: - State

    /// `GET /api/state/full` with the four `with_*=true` flags so the
    /// daemon actually populates `head_joints` (7 floats: index 0 =
    /// body_yaw, 1..6 = stewart motor angles), `body_yaw`,
    /// `antennas_position`, and `passive_joints`. Without these flags
    /// the daemon returns those fields as `null` — that's why the
    /// avatar's Stewart linkage couldn't animate before.
    public func fullState() async throws -> RobotState {
        let (data, status) = try await get(
            path: "/api/state/full",
            query: Self.fullStateQuery
        )
        try ensureOK(status: status, body: data)
        do {
            return try JSONDecoder().decode(RobotState.self, from: data)
        } catch {
            throw RobotLinkError.decode(message: "fullState: \(error)")
        }
    }

    /// Query string for state fetches. Shared by REST + WS.
    public static let fullStateQuery =
        "with_head_joints=true&with_body_yaw=true&with_antenna_positions=true&with_passive_joints=true"

    // MARK: - Motion

    /// `POST /api/move/set_target` — instant target update (wire schema:
    /// `FullBodyTarget`). Intended for streaming at ~50 Hz from `TargetStreamer`.
    /// Pre-clamps to safety limits.
    public func setTarget(_ target: MotionTarget) async throws {
        let clamped = SafetyLimits.clamp(target)
        let body = try JSONEncoder().encode(clamped)
        let (data, status) = try await post(path: "/api/move/set_target", body: body)
        try ensureOK(status: status, body: data)
    }

    /// `POST /api/move/goto` — smooth interpolated motion (wire schema:
    /// `GotoModelRequest`). Use for gestures ≥0.5 s, not for streaming control.
    ///
    /// **Velocity guard rail**: when a head pose is supplied, the
    /// implied average velocity (`Δangle / duration`) is checked
    /// against `SafetyLimits.maxJointVelocityRadPerS`. If the caller
    /// asked for a duration that would exceed the ceiling, the
    /// duration is *stretched* to the minimum that respects the cap.
    /// Slow / normal gotos pass through unchanged. This protects the
    /// hardware from a callsite that picks too short a duration for
    /// a large delta — no slowdown for legitimate fast moves, only
    /// unsafe ones.
    public func goto(
        headPose: RPYPose? = nil,
        antennas: Antennas? = nil,
        bodyYaw: Double? = nil,
        durationS: Double,
        interpolation: Interpolation = .minjerk
    ) async throws {
        struct Body: Encodable {
            let head_pose: RPYPose?
            let antennas: [Double]?
            let body_yaw: Double?
            let duration: Double
            let interpolation: String
        }
        let safeDuration = try await safeGotoDuration(target: headPose,
                                                       requested: durationS)
        let payload = Body(
            head_pose: headPose,
            antennas: antennas.map { [$0.right, $0.left] },
            body_yaw: bodyYaw,
            duration: safeDuration,
            interpolation: interpolation.rawValue
        )
        let body = try JSONEncoder().encode(payload)
        let (data, status) = try await post(path: "/api/move/goto", body: body)
        try ensureOK(status: status, body: data)
    }

    /// Compute the safest duration for a goto: max(requested, minimum
    /// implied by the velocity ceiling). When the requested duration
    /// already keeps every joint under the cap, returns it unchanged.
    /// When it doesn't, returns the minimum that does. Logs the
    /// stretch so excessive callsites are visible in telemetry.
    private func safeGotoDuration(target: RPYPose?,
                                   requested: TimeInterval) async throws
    -> TimeInterval {
        guard let target else { return requested }
        let current: RPYPose
        do {
            current = try await fullState().headPose
        } catch {
            // If state read fails, fall back to a conservative
            // assumption: treat the move as if every axis travelled
            // its full range. That over-stretches at most by a
            // constant factor, which is the safer error.
            let worstCase = SafetyLimits.headYawMax
            let safe = worstCase / SafetyLimits.maxJointVelocityRadPerS
            return max(requested, safe)
        }
        let minSafe = SafetyLimits.minGotoDuration(currentHead: current,
                                                    targetHead: target)
        if requested < minSafe {
            await logBus.publish(.error(
                scope: "goto.velocity_clamp",
                message: "stretched \(String(format: "%.3f", requested))s → \(String(format: "%.3f", minSafe))s to keep ≤ \(SafetyLimits.maxJointVelocityRadPerS) rad/s",
                recoverable: true))
            return minSafe
        }
        return requested
    }

    /// Maps to the daemon's `InterpolationTechnique` enum.
    public enum Interpolation: String, Sendable {
        case linear, minjerk, easeInOut = "ease_in_out", cartoon
    }

    /// `POST /api/move/stop`
    public func stopMove() async throws {
        let (data, status) = try await post(path: "/api/move/stop", body: Data())
        try ensureOK(status: status, body: data)
    }

    /// `GET /api/move/running`. Per the wiki note: `is_move_running` is
    /// not exposed in `state/full`; derive from this endpoint being
    /// non-empty. Used by the emotion safety cap to detect when a
    /// recorded move has finished.
    public func isMoveRunning() async throws -> Bool {
        let (data, status) = try await get(path: "/api/move/running")
        try ensureOK(status: status, body: data)
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            return !list.isEmpty
        }
        if let obj = try? JSONSerialization.jsonObject(with: data)
                          as? [String: Any] {
            return !obj.isEmpty
        }
        return false
    }

    /// Wake the bot gently. Single slow `minjerk` goto from the slumped
    /// sleep pose up to neutral — same easing curve as `look_at`, just
    /// over a longer (2 s) duration. Avoids the daemon's recorded
    /// `wake_up` animation (which read as snappy) and avoids chained
    /// gotos (which were a behaviour change just before "no video /
    /// no audio" started — keeping the move minimal so the daemon
    /// can't get confused).
    ///
    /// Pre-seed step explained: the daemon stores a commanded
    /// `set_target` independent of motor mode. While motors are
    /// disabled (sleeping) it sits at whatever was last sent —
    /// typically (0, 0, 0) at boot or a stale face-tracker pose. When
    /// `setMotorMode(.enabled)` fires, motors snap from physical
    /// position (slumped) to that stale target *instantly*. That
    /// snap is the visible "pop" the user reported, after which the
    /// goto from (0, 0, 0) to (0, 0, 0) had nothing to interpolate.
    /// Pre-seeding `set_target` with the current physical head pose
    /// makes motor engagement a no-op transition, so the goto can
    /// own the entire visible motion.
    ///
    /// `setMotorMode` errors are swallowed (`try?`): if the daemon
    /// rejects the mode change transiently, the goto still attempts
    /// and the second `setMotorMode` re-asserts.
    public func wakeUp() async throws {
        // Orchestrated on the BOT now (`POST :8042/api/motion/wake_up`)
        // so the on-bot MotionGuard can reset its slew baseline to
        // the current physical pose BEFORE the pre-seed `setTarget`
        // is sent. The previous Swift composite (setTarget → enable
        // → goto) sent the pre-seed through slew limiters that
        // clamped it against the prior face-tracker target — the
        // motor enable then snapped the head from physical pose to
        // the clamped target, which read as an aggressive wake. The
        // on-bot path also bumps the goto duration from 2 s → 3.5 s
        // by default for a calmer swing up.
        let url = endpoint.motionURL("/api/motion/wake_up")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        let (data, status) = try await perform(req, label: "/api/motion/wake_up")
        if status != 200 {
            // Fall back to the legacy Swift composite if the bot's
            // relay is pre-v0.2 (no `/api/motion/wake_up` yet). At
            // that point the user can update the relay; until then
            // they get the old behaviour.
            await logBus.publish(.sidecarLog(
                sidecar: "robot-link",
                level: .warn,
                message: "wake_up: on-bot endpoint returned \(status); falling back to Swift composite",
                fields: ["body": String(data: data, encoding: .utf8) ?? ""]
            ))
            try await legacyWakeUpComposite()
        }
    }

    /// Legacy three-step wake composite. Kept for the rare case the
    /// on-bot relay is on an older build. New deployments should
    /// reach the on-bot `/api/motion/wake_up` orchestrator above.
    private func legacyWakeUpComposite() async throws {
        let anchor: RPYPose
        if let snapshot = try? await fullState() {
            anchor = snapshot.headPose
        } else {
            anchor = RPYPose(roll: 0, pitch: 0, yaw: 0)
        }
        try? await setTarget(MotionTarget(headPose: anchor))
        try? await Task.sleep(nanoseconds: 50_000_000)
        try? await setMotorMode(.enabled)
        try? await Task.sleep(nanoseconds: 150_000_000)
        try await goto(
            headPose: RPYPose(roll: 0, pitch: 0, yaw: 0),
            durationS: 3.5,
            interpolation: .minjerk
        )
        try? await setMotorMode(.enabled)
    }

    /// Mirror the SDK's `goto_sleep()`: play the slump animation, wait for
    /// it to land (~2.7 s), then disable motors so the head rests gently.
    public func goToSleep() async throws {
        let (data, status) = try await post(path: "/api/move/play/goto_sleep", body: Data())
        try ensureOK(status: status, body: data)
        try? await Task.sleep(nanoseconds: 2_700_000_000)
        try? await setMotorMode(.disabled)
    }

    /// `POST /api/move/play/recorded-move-dataset/{dataset}/{move}` — play
    /// a recorded move (an "emotion") from a Hugging Face dataset such as
    /// `pollen-robotics/reachy-mini-emotions-library`.
    public func playRecordedMove(dataset: String, move: String) async throws {
        let path = "/api/move/play/recorded-move-dataset/\(dataset)/\(move)"
        let (data, status) = try await post(path: path, body: Data())
        try ensureOK(status: status, body: data)
    }

    /// `GET /api/move/recorded-move-datasets/list/{dataset}` — list moves
    /// available in a dataset.
    public func listRecordedMoves(dataset: String) async throws -> [String] {
        let path = "/api/move/recorded-move-datasets/list/\(dataset)"
        let (data, status) = try await get(path: path)
        try ensureOK(status: status, body: data)
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    // MARK: - Motors

    /// `POST /api/motors/set_mode/{mode}`
    public func setMotorMode(_ mode: MotorMode) async throws {
        let path = "/api/motors/set_mode/\(mode.rawValue)"
        let (data, status) = try await post(path: path, body: Data())
        try ensureOK(status: status, body: data)
    }

    // MARK: - Internals

    private func get(path: String, query: String? = nil) async throws -> (Data, Int) {
        let url = query.map { endpoint.apiURL(path, query: $0) }
                   ?? endpoint.apiURL(path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return try await perform(req, label: path)
    }

    private func post(path: String, body: Data) async throws -> (Data, Int) {
        // Motion-bearing endpoints get rewritten to the on-bot
        // motion-guard at `:motionPort/api/motion/*` (if configured)
        // so the bot enforces slew / velocity / duration / allowlist
        // / yaw-delta limits before forwarding to the daemon. Other
        // endpoints (state, daemon health) pass through unchanged.
        let url = Self.isMotionPath(path)
            ? endpoint.motionURL(path)
            : endpoint.apiURL(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await perform(req, label: path)
    }

    private static func isMotionPath(_ path: String) -> Bool {
        if path == "/api/move/set_target" { return true }
        if path == "/api/move/goto" { return true }
        if path == "/api/move/stop_move" { return true }
        if path == "/api/move/stop" { return true }
        if path.hasPrefix("/api/motors/set_mode/") { return true }
        if path.hasPrefix("/api/move/play/") { return true }
        return false
    }

    private func perform(_ req: URLRequest, label: String) async throws -> (Data, Int) {
        let started = Date()
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let ms = Date().timeIntervalSince(started) * 1000
            await logBus.publish(.robotLink(endpoint: label, status: status, latencyMs: ms))
            return (data, status)
        } catch {
            let ms = Date().timeIntervalSince(started) * 1000
            await logBus.publish(.robotLink(endpoint: label, status: 0, latencyMs: ms))
            throw RobotLinkError.transport(message: "\(label): \(error.localizedDescription)")
        }
    }

    private func ensureOK(status: Int, body: Data) throws {
        guard (200..<300).contains(status) else {
            let s = String(data: body, encoding: .utf8) ?? "<binary>"
            throw RobotLinkError.http(status: status, body: s)
        }
    }

    private nonisolated static func decodeDaemonStatus(_ data: Data) -> DaemonStatus {
        // Daemon shapes vary by version; salvage a best-effort decode and pass
        // through whatever's there. The dashboard cares about `period_ms`.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return DaemonStatus(periodMs: nil, readDtMs: nil, writeDtMs: nil, raw: nil)
        }

        let mc = json["motor_controller"] as? [String: Any] ?? json
        let period = (mc["period_ms"] as? Double) ?? extractMs(mc["period"])
        let read = (mc["read_dt_ms"] as? Double) ?? extractMs(mc["read_dt"])
        let write = (mc["write_dt_ms"] as? Double) ?? extractMs(mc["write_dt"])
        let raw = json.compactMapValues { "\($0)" }
        return DaemonStatus(periodMs: period, readDtMs: read, writeDtMs: write, raw: raw)
    }

    private nonisolated static func extractMs(_ any: Any?) -> Double? {
        if let s = any as? String,
           let v = Double(s.replacingOccurrences(of: "ms", with: "")
                            .trimmingCharacters(in: .whitespaces)) {
            return v
        }
        return nil
    }
}

extension SafetyLimits {
    /// Pre-clamp every component of a motion target to its valid range. The
    /// daemon also clamps internally; this keeps the dashboard honest about
    /// what was requested vs. what was sent.
    public static func clamp(_ target: MotionTarget) -> MotionTarget {
        var t = target
        if var pose = target.headPose {
            pose.roll = clamp(pose.roll, to: headRollMax)
            pose.pitch = clamp(pose.pitch, to: headPitchMax)
            pose.yaw = clamp(pose.yaw, to: headYawMax)
            t.headPose = pose
        }
        if let body = target.bodyYaw {
            t.bodyYaw = clamp(body, to: bodyYawMax)
        }
        return t
    }
}
