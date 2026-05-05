import Foundation

/// A 4x4 SE(3) homogeneous transform expressed as a row-major 16-element array.
///
/// This matches the wire format used by the Reachy Mini daemon for the `head`
/// field of `set_target` payloads: `[r00, r01, r02, tx, r10, r11, r12, ty,
/// r20, r21, r22, tz, 0, 0, 0, 1]`.
public struct HeadPose: Sendable, Equatable, Hashable, Codable {
    public var matrix: [Double]

    public init(matrix: [Double]) {
        precondition(matrix.count == 16, "HeadPose matrix must have exactly 16 entries")
        self.matrix = matrix
    }

    /// Identity pose: head looking straight ahead, no translation.
    public static let identity = HeadPose(matrix: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ])

    /// Build a pose from intrinsic XYZ Euler rotations and a translation in meters.
    /// Rotation order matches `R.from_euler("xyz", [roll, pitch, yaw])` in scipy
    /// (memory: this is the convention the existing face tracker uses).
    public static func rpy(
        roll: Angle = .radians(0),
        pitch: Angle = .radians(0),
        yaw: Angle = .radians(0),
        x: Length = .meters(0),
        y: Length = .meters(0),
        z: Length = .meters(0)
    ) -> HeadPose {
        let r = roll.radians
        let p = pitch.radians
        let yw = yaw.radians

        let cr = cos(r), sr = sin(r)
        let cp = cos(p), sp = sin(p)
        let cy = cos(yw), sy = sin(yw)

        // Intrinsic XYZ: R = Rx(r) * Ry(p) * Rz(y)
        let r00 = cp * cy
        let r01 = -cp * sy
        let r02 = sp
        let r10 = sr * sp * cy + cr * sy
        let r11 = -sr * sp * sy + cr * cy
        let r12 = -sr * cp
        let r20 = -cr * sp * cy + sr * sy
        let r21 = cr * sp * sy + sr * cy
        let r22 = cr * cp

        return HeadPose(matrix: [
            r00, r01, r02, x.meters,
            r10, r11, r12, y.meters,
            r20, r21, r22, z.meters,
            0, 0, 0, 1,
        ])
    }
}

/// Radian targets for the right and left antennas.
public struct Antennas: Sendable, Equatable, Hashable, Codable {
    public var right: Double
    public var left: Double

    public init(rightRad: Double = 0, leftRad: Double = 0) {
        self.right = rightRad
        self.left = leftRad
    }

    public static let zero = Antennas()
}
