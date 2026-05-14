import Testing
import Foundation

/// Unit tests for the image-coordinate → head-pose-delta math used
/// by `LookAtTool.performLook`. The tool itself isn't directly
/// testable because it goes through AppServices; this verifies the
/// arithmetic in isolation so we know the conversion is right
/// regardless of the surrounding wiring.
@Suite("LookAt geometry")
struct LookAtMathTests {
    // Re-implement the math here. The tool's `performLook` is in
    // the Rocky target which depends on the full app graph; the
    // pure math fits in this test module without dragging Rocky
    // in.
    // Calibrated FOVs of the cropped/scaled frame the brain
    // actually receives (NOT the raw IMX708 lens spec, which is
    // wider). Match MacFaceTracker's values — that controller has
    // been validated against live face tracking.
    static let horizontalFOVRad: Double = 65.0 * .pi / 180.0
    static let verticalFOVRad: Double = 39.0 * .pi / 180.0

    private static func delta(x: Double, y: Double) -> (yaw: Double, pitch: Double) {
        // Yaw sign: daemon convention is positive yaw = left.
        // An object on the right side of the image (x > 0.5) needs
        // the camera to turn RIGHT → NEGATIVE yaw delta. Match the
        // sign `MacFaceTracker.swift:466` uses (`-un * hfov/2`).
        let yaw = -(x - 0.5) * horizontalFOVRad
        let pitch = (y - 0.5) * verticalFOVRad
        return (yaw, pitch)
    }

    @Test("centre of frame → no movement")
    func centreIsZero() {
        let d = Self.delta(x: 0.5, y: 0.5)
        #expect(abs(d.yaw) < 1e-9)
        #expect(abs(d.pitch) < 1e-9)
    }

    @Test("right edge → yaw −HFOV/2 (head turns right, away from +yaw=left)")
    func rightEdgeYawsRight() {
        let d = Self.delta(x: 1.0, y: 0.5)
        #expect(abs(d.yaw - (-32.5 * .pi / 180.0)) < 1e-9)
        #expect(abs(d.pitch) < 1e-9)
    }

    @Test("left edge → yaw +HFOV/2 (head turns left, towards +yaw=left)")
    func leftEdgeYawsLeft() {
        let d = Self.delta(x: 0.0, y: 0.5)
        #expect(abs(d.yaw - (32.5 * .pi / 180.0)) < 1e-9)
        #expect(abs(d.pitch) < 1e-9)
    }

    @Test("bottom edge → pitch +VFOV/2 (≈ +19.5°)")
    func bottomEdgePitchesDown() {
        let d = Self.delta(x: 0.5, y: 1.0)
        #expect(abs(d.pitch - (19.5 * .pi / 180.0)) < 1e-9)
        #expect(abs(d.yaw) < 1e-9)
    }

    @Test("top edge → pitch −VFOV/2 (≈ −19.5°)")
    func topEdgePitchesUp() {
        let d = Self.delta(x: 0.5, y: 0.0)
        #expect(abs(d.pitch - (-19.5 * .pi / 180.0)) < 1e-9)
        #expect(abs(d.yaw) < 1e-9)
    }

    @Test("top-right corner: yaw turns right (-), pitch up (-)")
    func cornerCombines() {
        let d = Self.delta(x: 1.0, y: 0.0)
        #expect(d.yaw < 0)
        #expect(d.pitch < 0)
    }
}
