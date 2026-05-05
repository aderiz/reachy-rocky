import Testing
import RockyKit
import Foundation

@Suite("HeadPose")
struct PoseTests {
    @Test("identity is a 16-element matrix with 1s on the diagonal")
    func identity() {
        let p = HeadPose.identity
        #expect(p.matrix.count == 16)
        #expect(p.matrix[0] == 1)
        #expect(p.matrix[5] == 1)
        #expect(p.matrix[10] == 1)
        #expect(p.matrix[15] == 1)
    }

    @Test("rpy(0,0,0) equals identity (within tolerance)")
    func zeroRpy() {
        let p = HeadPose.rpy()
        for i in 0..<16 {
            #expect(abs(p.matrix[i] - HeadPose.identity.matrix[i]) < 1e-9)
        }
    }

    @Test("translation lands in column 3, rows 0/1/2")
    func translation() {
        let p = HeadPose.rpy(x: .millimeters(10), y: .millimeters(0), z: .millimeters(20))
        #expect(abs(p.matrix[3]  - 0.010) < 1e-9)
        #expect(abs(p.matrix[7]  - 0.000) < 1e-9)
        #expect(abs(p.matrix[11] - 0.020) < 1e-9)
    }
}

@Suite("SafetyLimits")
struct SafetyTests {
    @Test("clamp respects symmetric range")
    func clampSymmetric() {
        let limit = SafetyLimits.bodyYawMax
        #expect(SafetyLimits.clamp(limit + 1, to: limit) == limit)
        #expect(SafetyLimits.clamp(-(limit + 1), to: limit) == -limit)
        #expect(SafetyLimits.clamp(0, to: limit) == 0)
    }
}

@Suite("RobotState codec")
struct RobotStateCodingTests {
    /// Sample captured live from daemon v1.7.1 (2026-05-05).
    @Test("decodes the live daemon state shape")
    func decode() throws {
        let json = """
        {
            "control_mode": "enabled",
            "head_pose": {
                "x": 0.00003, "y": 0.0028, "z": -0.0018,
                "roll": 0.0623, "pitch": 0.0155, "yaw": 0.0103
            },
            "head_joints": null,
            "body_yaw": 0.0169,
            "antennas_position": [-0.1718, 0.1718],
            "timestamp": "2026-05-05T12:18:28.050628Z",
            "passive_joints": null,
            "doa": null
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(RobotState.self, from: json)
        #expect(s.controlMode == .enabled)
        #expect(abs(s.headPose.yaw - 0.0103) < 1e-9)
        #expect(s.bodyYaw == 0.0169)
        #expect(abs(s.antennasPosition.right - -0.1718) < 1e-9)
        #expect(abs(s.antennasPosition.left  -  0.1718) < 1e-9)
        #expect(s.timestamp == "2026-05-05T12:18:28.050628Z")
    }
}

@Suite("MotionTarget wire format")
struct MotionTargetCodingTests {
    @Test("encodes the FullBodyTarget shape with target_ prefixed keys")
    func encode() throws {
        let t = MotionTarget(
            headPose: RPYPose(roll: 0, pitch: 0.1, yaw: -0.2),
            antennas: Antennas(rightRad: 0.3, leftRad: -0.3),
            bodyYaw: 0.05
        )
        let data = try JSONEncoder().encode(t)
        let any = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(any?["target_head_pose"] != nil, "expected target_head_pose key")
        #expect(any?["target_antennas"] != nil)
        #expect(any?["target_body_yaw"] as? Double == 0.05)

        let head = any?["target_head_pose"] as? [String: Double]
        #expect(head?["pitch"] == 0.1)
        #expect(head?["yaw"] == -0.2)

        let antennas = any?["target_antennas"] as? [Double]
        #expect(antennas == [0.3, -0.3])
    }
}
