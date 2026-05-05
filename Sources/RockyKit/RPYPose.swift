import Foundation

/// XYZ+RPY pose, matching the daemon's `XYZRPYPose` schema.
///
/// Translation is in meters; rotations are intrinsic XYZ Euler angles in
/// radians (matches `R.from_euler("xyz", [roll, pitch, yaw])` in scipy).
public struct RPYPose: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var roll: Double
    public var pitch: Double
    public var yaw: Double

    public init(
        x: Double = 0,
        y: Double = 0,
        z: Double = 0,
        roll: Double = 0,
        pitch: Double = 0,
        yaw: Double = 0
    ) {
        self.x = x
        self.y = y
        self.z = z
        self.roll = roll
        self.pitch = pitch
        self.yaw = yaw
    }

    public static let zero = RPYPose()

    /// Convenience: build a pure-rotation pose with degree inputs.
    public static func degrees(
        roll: Double = 0,
        pitch: Double = 0,
        yaw: Double = 0,
        xMeters: Double = 0,
        yMeters: Double = 0,
        zMeters: Double = 0
    ) -> RPYPose {
        let toRad = Double.pi / 180.0
        return RPYPose(
            x: xMeters, y: yMeters, z: zMeters,
            roll: roll * toRad, pitch: pitch * toRad, yaw: yaw * toRad
        )
    }
}
