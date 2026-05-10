import Foundation

/// Observable snapshot of the most recent world-frame face target,
/// stamped on `AppServices` and rendered by the Vision card overlay.
///
/// Lives in the app target (not in `Perception` or `Vision`) because
/// it's a presentation concern — `MacFaceTracker.targets` emits a raw
/// tuple `(yawRad, pitchRad, decay)` which can't be stored as an
/// `@Observable` property; this struct is the typed shape we mirror
/// to SwiftUI. Created during the v0.2 rebuild after the dormant
/// `RockyVision.FaceTrackerService.Target` type was deleted along
/// with its sidecar.
public struct FaceTargetSnapshot: Sendable, Equatable {
    public let yawRad: Double
    public let pitchRad: Double
    public let decayActive: Bool

    public init(yawRad: Double, pitchRad: Double, decayActive: Bool) {
        self.yawRad = yawRad
        self.pitchRad = pitchRad
        self.decayActive = decayActive
    }
}
