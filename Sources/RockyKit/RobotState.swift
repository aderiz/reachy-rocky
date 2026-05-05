import Foundation

/// Snapshot of the robot's current state, mirroring the daemon's `/api/state/full`
/// shape. Field names use Swift conventions; `CodingKeys` map to the wire format.
public struct RobotState: Sendable, Equatable, Hashable, Codable {
    public var head: HeadPose
    public var antennas: Antennas
    public var bodyYaw: Double
    public var motorMode: MotorMode
    public var isMoveRunning: Bool

    public init(
        head: HeadPose = .identity,
        antennas: Antennas = .zero,
        bodyYaw: Double = 0,
        motorMode: MotorMode = .enabled,
        isMoveRunning: Bool = false
    ) {
        self.head = head
        self.antennas = antennas
        self.bodyYaw = bodyYaw
        self.motorMode = motorMode
        self.isMoveRunning = isMoveRunning
    }

    enum CodingKeys: String, CodingKey {
        case head
        case antennas
        case bodyYaw = "body_yaw"
        case motorMode = "motor_mode"
        case isMoveRunning = "is_move_running"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The daemon emits `head` as a flat 16-element array.
        let matrix = try c.decode([Double].self, forKey: .head)
        self.head = HeadPose(matrix: matrix)
        // `antennas` arrives as `[right, left]` in radians.
        let pair = try c.decode([Double].self, forKey: .antennas)
        guard pair.count == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .antennas, in: c,
                debugDescription: "Expected antennas to be [right_rad, left_rad]"
            )
        }
        self.antennas = Antennas(rightRad: pair[0], leftRad: pair[1])
        self.bodyYaw = try c.decode(Double.self, forKey: .bodyYaw)
        self.motorMode = try c.decode(MotorMode.self, forKey: .motorMode)
        self.isMoveRunning = try c.decode(Bool.self, forKey: .isMoveRunning)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(head.matrix, forKey: .head)
        try c.encode([antennas.right, antennas.left], forKey: .antennas)
        try c.encode(bodyYaw, forKey: .bodyYaw)
        try c.encode(motorMode, forKey: .motorMode)
        try c.encode(isMoveRunning, forKey: .isMoveRunning)
    }
}

/// A target packet streamed to the daemon at 50 Hz by `RobotLink.TargetStreamer`.
public struct MotionTarget: Sendable, Equatable, Hashable, Codable {
    public var head: HeadPose?
    public var antennas: Antennas?
    public var bodyYaw: Double?

    public init(head: HeadPose? = nil, antennas: Antennas? = nil, bodyYaw: Double? = nil) {
        self.head = head
        self.antennas = antennas
        self.bodyYaw = bodyYaw
    }

    enum CodingKeys: String, CodingKey {
        case head
        case antennas
        case bodyYaw = "body_yaw"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let m = try c.decodeIfPresent([Double].self, forKey: .head) {
            self.head = HeadPose(matrix: m)
        } else {
            self.head = nil
        }
        if let pair = try c.decodeIfPresent([Double].self, forKey: .antennas) {
            guard pair.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .antennas, in: c,
                    debugDescription: "Expected antennas to be [right_rad, left_rad]"
                )
            }
            self.antennas = Antennas(rightRad: pair[0], leftRad: pair[1])
        } else {
            self.antennas = nil
        }
        self.bodyYaw = try c.decodeIfPresent(Double.self, forKey: .bodyYaw)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(head?.matrix, forKey: .head)
        if let a = antennas {
            try c.encode([a.right, a.left], forKey: .antennas)
        }
        try c.encodeIfPresent(bodyYaw, forKey: .bodyYaw)
    }
}
