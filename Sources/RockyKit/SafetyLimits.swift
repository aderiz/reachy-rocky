import Foundation

/// Reachy Mini joint limits, in radians. The daemon also clamps internally,
/// but Rocky pre-clamps so the dashboard reflects what was actually requested.
/// Source: docs/concepts/safety-limits.md.
public enum SafetyLimits {
    public static let headPitchMax: Double = 40.0 * .pi / 180.0  // ±40°
    public static let headRollMax:  Double = 40.0 * .pi / 180.0  // ±40°
    public static let headYawMax:   Double = 180.0 * .pi / 180.0 // ±180°
    public static let bodyYawMax:   Double = 160.0 * .pi / 180.0 // ±160°
    /// Max absolute difference between head yaw and body yaw.
    public static let yawDeltaMax:  Double = 65.0 * .pi / 180.0  // ≤65°

    /// Hard ceiling on commanded *or* observed joint angular velocity,
    /// in radians per second. Above this value motion reads as
    /// aggressive (snap-to-limits / motor strain risk). Used as:
    ///
    /// - **Goto clamp**: a `goto(headPose:durationS:)` whose implied
    ///   average velocity (`Δangle / duration`) exceeds this is
    ///   stretched to a longer duration that respects the ceiling.
    ///   Slow / normal gotos pass through unchanged.
    /// - **Recorded-move watchdog**: the streamed state from the
    ///   daemon is sampled while a recorded emotion plays. If any
    ///   joint's instantaneous velocity exceeds this, the move is
    ///   force-stopped — the authored animation has misbehaved and
    ///   continuing would risk damage.
    ///
    /// 3.0 rad/s ≈ 172°/s. Comfortably above what `express` and the
    /// face tracker (1.2 rad/s controller cap) ever produce, while
    /// still well below the motor's hardware limit. Tune up only
    /// after observing motion at higher speeds and confirming the
    /// head doesn't slam its limits.
    public static let maxJointVelocityRadPerS: Double = 3.0

    @inlinable
    public static func clamp(_ value: Double, to limit: Double) -> Double {
        min(max(value, -limit), limit)
    }

    /// Minimum duration a `goto(target)` may use, given the joint angle
    /// deltas and the velocity ceiling. Returns 0 when no head pose is
    /// supplied (nothing to clamp). Used by `RobotLinkClient.goto` to
    /// stretch over-fast gotos rather than reject them.
    public static func minGotoDuration(currentHead: RPYPose?,
                                        targetHead: RPYPose?) -> TimeInterval {
        guard let cur = currentHead, let tgt = targetHead else { return 0 }
        let dRoll  = abs(tgt.roll  - cur.roll)
        let dPitch = abs(tgt.pitch - cur.pitch)
        let dYaw   = abs(tgt.yaw   - cur.yaw)
        let maxDelta = max(dRoll, dPitch, dYaw)
        return maxDelta / maxJointVelocityRadPerS
    }
}

public enum MotorMode: String, Sendable, Codable, CaseIterable {
    case enabled
    case disabled
    case gravityCompensation = "gravity_compensation"
}
