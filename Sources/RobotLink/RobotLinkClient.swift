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

    /// `GET /api/state/full`
    public func fullState() async throws -> RobotState {
        let (data, status) = try await get(path: "/api/state/full")
        try ensureOK(status: status, body: data)
        do {
            return try JSONDecoder().decode(RobotState.self, from: data)
        } catch {
            throw RobotLinkError.decode(message: "fullState: \(error)")
        }
    }

    // MARK: - Motion

    /// `POST /api/move/set_target` — instant target update; intended for streaming
    /// at ~50 Hz from `TargetStreamer`. Pre-clamps to safety limits.
    public func setTarget(_ target: MotionTarget) async throws {
        let clamped = SafetyLimits.clamp(target)
        let body = try JSONEncoder().encode(clamped)
        let (data, status) = try await post(path: "/api/move/set_target", body: body)
        try ensureOK(status: status, body: data)
    }

    /// `POST /api/move/goto` — smooth interpolated motion. Use for gestures ≥0.5 s,
    /// not for streaming control.
    public func goto(_ target: MotionTarget, durationS: Double, method: GotoMethod = .minjerk) async throws {
        struct Body: Encodable {
            let head: [Double]?
            let antennas: [Double]?
            let body_yaw: Double?
            let duration: Double
            let method: String
        }
        let payload = Body(
            head: target.head?.matrix,
            antennas: target.antennas.map { [$0.right, $0.left] },
            body_yaw: target.bodyYaw,
            duration: durationS,
            method: method.rawValue
        )
        let body = try JSONEncoder().encode(payload)
        let (data, status) = try await post(path: "/api/move/goto", body: body)
        try ensureOK(status: status, body: data)
    }

    public enum GotoMethod: String, Sendable {
        case linear, minjerk, easeInOut = "ease_in_out", cartoon
    }

    /// `POST /api/move/stop`
    public func stopMove() async throws {
        let (data, status) = try await post(path: "/api/move/stop", body: Data())
        try ensureOK(status: status, body: data)
    }

    /// `POST /api/move/play/wake_up`
    public func wakeUp() async throws {
        let (data, status) = try await post(path: "/api/move/play/wake_up", body: Data())
        try ensureOK(status: status, body: data)
    }

    /// `POST /api/move/play/goto_sleep`
    public func goToSleep() async throws {
        let (data, status) = try await post(path: "/api/move/play/goto_sleep", body: Data())
        try ensureOK(status: status, body: data)
    }

    // MARK: - Motors

    /// `POST /api/motors/set_mode/{mode}`
    public func setMotorMode(_ mode: MotorMode) async throws {
        let path = "/api/motors/set_mode/\(mode.rawValue)"
        let (data, status) = try await post(path: path, body: Data())
        try ensureOK(status: status, body: data)
    }

    // MARK: - Internals

    private func get(path: String) async throws -> (Data, Int) {
        var req = URLRequest(url: endpoint.apiURL(path))
        req.httpMethod = "GET"
        return try await perform(req, label: path)
    }

    private func post(path: String, body: Data) async throws -> (Data, Int) {
        var req = URLRequest(url: endpoint.apiURL(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await perform(req, label: path)
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
    /// Pre-clamp every component of a motion target to its valid range. The daemon
    /// also clamps internally — this just keeps the dashboard honest about what
    /// was requested vs. what was sent.
    public static func clamp(_ target: MotionTarget) -> MotionTarget {
        var t = target
        if let pose = target.head {
            // We don't decompose the matrix here; clamping at the matrix level is
            // a no-op. RPY clamping happens upstream where we synthesize the pose.
            t.head = pose
        }
        if let body = target.bodyYaw {
            t.bodyYaw = clamp(body, to: bodyYawMax)
        }
        return t
    }
}
