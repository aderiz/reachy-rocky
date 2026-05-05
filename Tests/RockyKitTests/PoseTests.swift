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
    @Test("decodes the daemon's wire shape")
    func decode() throws {
        let json = """
        {
            "head": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1],
            "antennas": [0.1, -0.1],
            "body_yaw": 0.5,
            "motor_mode": "enabled",
            "is_move_running": false
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(RobotState.self, from: json)
        #expect(s.antennas.right == 0.1)
        #expect(s.antennas.left  == -0.1)
        #expect(s.bodyYaw == 0.5)
        #expect(s.motorMode == .enabled)
        #expect(!s.isMoveRunning)
    }
}
