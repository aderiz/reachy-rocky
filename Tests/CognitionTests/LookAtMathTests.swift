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
    static let horizontalFOVRad: Double = 120.0 * .pi / 180.0
    static let defaultAspect: Double = 16.0 / 9.0

    private static func delta(x: Double, y: Double, aspect: Double) -> (yaw: Double, pitch: Double) {
        let vfov = horizontalFOVRad / max(aspect, 0.1)
        let yaw = (x - 0.5) * horizontalFOVRad
        let pitch = (y - 0.5) * vfov
        return (yaw, pitch)
    }

    @Test("centre of frame → no movement")
    func centreIsZero() {
        let d = Self.delta(x: 0.5, y: 0.5, aspect: 16.0 / 9.0)
        #expect(abs(d.yaw) < 1e-9)
        #expect(abs(d.pitch) < 1e-9)
    }

    @Test("right edge → yaw +HFOV/2 (≈ +60°)")
    func rightEdgeYawsRight() {
        let d = Self.delta(x: 1.0, y: 0.5, aspect: 16.0 / 9.0)
        #expect(abs(d.yaw - 60.0 * .pi / 180.0) < 1e-9)
        #expect(abs(d.pitch) < 1e-9)
    }

    @Test("left edge → yaw −HFOV/2 (≈ −60°)")
    func leftEdgeYawsLeft() {
        let d = Self.delta(x: 0.0, y: 0.5, aspect: 16.0 / 9.0)
        #expect(abs(d.yaw + 60.0 * .pi / 180.0) < 1e-9)
        #expect(abs(d.pitch) < 1e-9)
    }

    @Test("bottom edge → pitch +VFOV/2 at 16:9 (≈ +33.75°)")
    func bottomEdgePitchesDown() {
        let d = Self.delta(x: 0.5, y: 1.0, aspect: 16.0 / 9.0)
        let expected = 0.5 * Self.horizontalFOVRad / (16.0 / 9.0)
        #expect(abs(d.pitch - expected) < 1e-9)
        #expect(abs(d.yaw) < 1e-9)
    }

    @Test("top edge → pitch −VFOV/2")
    func topEdgePitchesUp() {
        let d = Self.delta(x: 0.5, y: 0.0, aspect: 16.0 / 9.0)
        let expected = -0.5 * Self.horizontalFOVRad / (16.0 / 9.0)
        #expect(abs(d.pitch - expected) < 1e-9)
        #expect(abs(d.yaw) < 1e-9)
    }

    @Test("4:3 frame → wider VFOV than 16:9")
    func aspect4By3HasWiderVFOV() {
        let d16 = Self.delta(x: 0.5, y: 1.0, aspect: 16.0 / 9.0)
        let d43 = Self.delta(x: 0.5, y: 1.0, aspect: 4.0 / 3.0)
        // VFOV ∝ 1 / aspect, so 4:3 (smaller aspect) → larger VFOV
        // → larger pitch delta at the bottom edge.
        #expect(d43.pitch > d16.pitch)
    }

    @Test("corner target combines yaw + pitch")
    func cornerCombines() {
        let d = Self.delta(x: 1.0, y: 0.0, aspect: 16.0 / 9.0)
        #expect(d.yaw > 0)
        #expect(d.pitch < 0)
    }
}
