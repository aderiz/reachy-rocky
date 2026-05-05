import Foundation

/// Snapshot of the robot's current state, mirroring the daemon's
/// `/api/state/full` response (verified live, daemon v1.7.1).
public struct RobotState: Sendable, Equatable, Hashable, Codable {
    public var controlMode: MotorMode
    public var headPose: RPYPose
    public var headJoints: [Double]?
    public var bodyYaw: Double
    public var antennasPosition: Antennas
    public var passiveJoints: [Double]?
    public var doa: DoA?
    public var timestamp: String?

    public struct DoA: Sendable, Equatable, Hashable, Codable {
        public let angleRad: Double?
        public let isSpeechDetected: Bool?

        enum CodingKeys: String, CodingKey {
            case angleRad = "angle_rad"
            case isSpeechDetected = "is_speech_detected"
        }
    }

    public init(
        controlMode: MotorMode = .enabled,
        headPose: RPYPose = .zero,
        headJoints: [Double]? = nil,
        bodyYaw: Double = 0,
        antennasPosition: Antennas = .zero,
        passiveJoints: [Double]? = nil,
        doa: DoA? = nil,
        timestamp: String? = nil
    ) {
        self.controlMode = controlMode
        self.headPose = headPose
        self.headJoints = headJoints
        self.bodyYaw = bodyYaw
        self.antennasPosition = antennasPosition
        self.passiveJoints = passiveJoints
        self.doa = doa
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case controlMode = "control_mode"
        case headPose = "head_pose"
        case headJoints = "head_joints"
        case bodyYaw = "body_yaw"
        case antennasPosition = "antennas_position"
        case passiveJoints = "passive_joints"
        case doa
        case timestamp
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.controlMode = try c.decode(MotorMode.self, forKey: .controlMode)
        self.headPose = try c.decode(RPYPose.self, forKey: .headPose)
        self.headJoints = try c.decodeIfPresent([Double].self, forKey: .headJoints)
        self.bodyYaw = try c.decode(Double.self, forKey: .bodyYaw)
        let pair = try c.decode([Double].self, forKey: .antennasPosition)
        guard pair.count == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .antennasPosition, in: c,
                debugDescription: "expected antennas_position to be [right_rad, left_rad]"
            )
        }
        self.antennasPosition = Antennas(rightRad: pair[0], leftRad: pair[1])
        self.passiveJoints = try c.decodeIfPresent([Double].self, forKey: .passiveJoints)
        self.doa = try c.decodeIfPresent(DoA.self, forKey: .doa)
        self.timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(controlMode, forKey: .controlMode)
        try c.encode(headPose, forKey: .headPose)
        try c.encodeIfPresent(headJoints, forKey: .headJoints)
        try c.encode(bodyYaw, forKey: .bodyYaw)
        try c.encode([antennasPosition.right, antennasPosition.left], forKey: .antennasPosition)
        try c.encodeIfPresent(passiveJoints, forKey: .passiveJoints)
        try c.encodeIfPresent(doa, forKey: .doa)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
    }
}

/// What we send to `POST /api/move/set_target`. Wire schema: `FullBodyTarget`.
///
/// Field names use the `target_` prefix on the wire; this differs from
/// `GotoModelRequest` which uses bare `head_pose` / `antennas` / `body_yaw`.
public struct MotionTarget: Sendable, Equatable, Hashable, Codable {
    public var headPose: RPYPose?
    public var antennas: Antennas?
    public var bodyYaw: Double?
    public var timestamp: String?

    public init(
        headPose: RPYPose? = nil,
        antennas: Antennas? = nil,
        bodyYaw: Double? = nil,
        timestamp: String? = nil
    ) {
        self.headPose = headPose
        self.antennas = antennas
        self.bodyYaw = bodyYaw
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case headPose = "target_head_pose"
        case antennas = "target_antennas"
        case bodyYaw = "target_body_yaw"
        case timestamp
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.headPose = try c.decodeIfPresent(RPYPose.self, forKey: .headPose)
        if let pair = try c.decodeIfPresent([Double].self, forKey: .antennas) {
            guard pair.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .antennas, in: c,
                    debugDescription: "expected target_antennas to be [right_rad, left_rad]"
                )
            }
            self.antennas = Antennas(rightRad: pair[0], leftRad: pair[1])
        } else {
            self.antennas = nil
        }
        self.bodyYaw = try c.decodeIfPresent(Double.self, forKey: .bodyYaw)
        self.timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(headPose, forKey: .headPose)
        if let a = antennas {
            try c.encode([a.right, a.left], forKey: .antennas)
        }
        try c.encodeIfPresent(bodyYaw, forKey: .bodyYaw)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
    }
}
