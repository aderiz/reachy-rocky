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

    @inlinable
    public static func clamp(_ value: Double, to limit: Double) -> Double {
        min(max(value, -limit), limit)
    }
}

public enum MotorMode: String, Sendable, Codable, CaseIterable {
    case enabled
    case disabled
    case gravityCompensation = "gravity_compensation"
}
