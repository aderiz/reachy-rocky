import Foundation
import Cognition
import RockyKit
import RobotLink

/// Point Rocky's head at a point in the current camera frame.
///
/// Designed for "Rocky, look at the cup" / "look over here" style
/// requests when face tracking is off (face tracking has no idea
/// about objects, just faces). The brain — which is vision-capable —
/// receives the camera frame with every turn and can identify the
/// target visually; this tool converts the brain's chosen image-
/// space coordinates into a head-pose delta and issues a fast
/// minjerk `goto`.
///
/// **Coordinate input.** `x`, `y` are normalised image-space
/// coordinates in `[0, 1]`, with origin at the **top-left** of the
/// frame (image convention, not screen convention). The brain
/// derives them by locating the target object in the JPEG passed
/// via the `imageProvider` closure.
///
/// **Camera FOV** — Reachy Mini's Sony IMX708 wide-angle lens
/// captures a documented 120° horizontal FOV (per
/// `docs/reference/hardware.md`). The vertical FOV is derived from
/// the frame's aspect ratio at use time (typically 16:9 → ~67.5°).
///
/// **Head pose target.** The current head yaw / pitch (read from
/// `services.lastRobotState`) is the baseline; the requested image
/// coordinate is converted to a delta and added:
///
/// ```
/// yawTarget   = currentYaw   + (x − 0.5) · HFOV
/// pitchTarget = currentPitch + (y − 0.5) · VFOV
/// ```
///
/// Targets are clamped to `SafetyLimits.headYawMax / headPitchMax`
/// before being issued.
///
/// **Motion.** A `goto` with a fast minjerk duration (0.7 s by
/// default) so the look reads as deliberate but quick.
/// `services.transitioningUntil` is bumped to suppress the 50 Hz
/// face-tracker streamer during the move, so a brief overlap
/// between this tool firing and the tracker's idle-look-around
/// (if enabled) doesn't fight the goto.
enum LookAtTool {

    /// Reachy Mini's IMX708 wide-angle horizontal FOV per
    /// `docs/reference/hardware.md`. The vertical FOV is derived
    /// from the input image's aspect ratio so 4:3 vs 16:9 sensor
    /// crops compute correctly.
    static let horizontalFOVRad: Double = 120.0 * .pi / 180.0

    /// Default frame aspect ratio when the brain doesn't tell us
    /// what it saw. The on-bot relay downscales to ~480 wide; the
    /// camera native is 16:9 so this is the safe default.
    static let defaultAspectRatio: Double = 16.0 / 9.0

    /// Minjerk duration for the look-at goto. Fast enough to read
    /// as immediate response to a verbal "look at that"; slow
    /// enough that the motors don't slam.
    static let durationS: Double = 0.7

    static func register(
        in registry: ToolRegistry,
        services: AppServices
    ) async {
        await registry.register(
            name: "look_at_object",
            description: """
                Point Rocky's head at a point in the **current \
                camera frame**. Use this when the user asks to look \
                at an object, a place, or anything visible in front \
                of Rocky — e.g. "look at the cup", "look over \
                here", "look at that book". You see the frame in \
                this turn — locate the target in it and pass its \
                centre as normalised coordinates: `x` from 0 (left \
                edge) to 1 (right edge), `y` from 0 (top edge) to 1 \
                (bottom edge). The tool handles the FOV-to-angle \
                conversion. \

                If you have a specific yaw/pitch angle in mind \
                (e.g. the user said "look 30 degrees left"), use \
                the `look_at` tool instead. \

                Optional `description` is logged for diagnostics. \
                Optional `aspect_ratio` (default 16:9) tells the \
                tool the frame's width-to-height ratio so the \
                vertical FOV is correct.
                """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "x": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Normalised horizontal image coordinate of the target, 0 (left) to 1 (right)."),
                    ]),
                    "y": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Normalised vertical image coordinate of the target, 0 (top) to 1 (bottom)."),
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Short label for what is being looked at (e.g. 'the red cup'). Logged for diagnostics."),
                    ]),
                    "aspect_ratio": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Frame width / height. Default 16:9 (1.78). Use the actual ratio of the frame you observed if it differs."),
                    ]),
                ]),
                "required": .array([.string("x"), .string("y")]),
            ]),
            handler: { [weak services] args in
                guard let services else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("services unavailable"),
                    ])
                }
                let xRaw = args.asObject?["x"]?.asNumber ?? 0.5
                let yRaw = args.asObject?["y"]?.asNumber ?? 0.5
                let aspect = args.asObject?["aspect_ratio"]?.asNumber
                    ?? Self.defaultAspectRatio
                let description = args.asObject?["description"]?.asString ?? ""

                // Clamp inputs — the brain might overshoot 0..1
                // edges if the target is partly off-frame.
                let x = max(0.0, min(1.0, xRaw))
                let y = max(0.0, min(1.0, yRaw))

                return await Self.performLook(
                    x: x, y: y, aspect: aspect,
                    description: description,
                    services: services
                )
            }
        )
    }

    /// The actual goto. Pulled out into a static function so the
    /// tool handler closure stays readable + so tests can drive
    /// the math without the registry.
    static func performLook(
        x: Double, y: Double, aspect: Double,
        description: String,
        services: AppServices
    ) async -> JSONValue {
        // Vertical FOV from the input aspect ratio. A wider frame
        // has a narrower VFOV for the same HFOV.
        let vfov = Self.horizontalFOVRad / max(aspect, 0.1)

        // Image-space → angle deltas. `x=0.5, y=0.5` is the centre
        // of the frame (no movement). y is positive **downward**
        // in image space; Reachy Mini's head pitch is positive
        // **downward** too (head tilts forward), so the sign is
        // preserved verbatim.
        let yawDelta = (x - 0.5) * Self.horizontalFOVRad
        let pitchDelta = (y - 0.5) * vfov

        // Read the current head pose. Fall back to zero if the
        // state stream hasn't delivered anything yet (cold start);
        // in that case the move just commands the absolute angle.
        let currentPose = await MainActor.run {
            services.lastRobotState?.headPose
        }
        let baseYaw = currentPose?.yaw ?? 0
        let basePitch = currentPose?.pitch ?? 0
        let baseRoll = currentPose?.roll ?? 0

        // Clamp to safety limits — head yaw ±180°, pitch ±40°.
        // Going beyond these is unsafe and the daemon would
        // reject anyway.
        let yawTarget = SafetyLimits.clamp(
            baseYaw + yawDelta, to: SafetyLimits.headYawMax
        )
        let pitchTarget = SafetyLimits.clamp(
            basePitch + pitchDelta, to: SafetyLimits.headPitchMax
        )

        let target = RPYPose(
            roll: baseRoll, pitch: pitchTarget, yaw: yawTarget
        )

        // Suppress the face-tracker streamer for the move duration
        // + a small tail. Idempotent if the streamer is already
        // gated (e.g. face tracking is off, transitioningUntil is
        // unused). When face tracking is on, this stops the
        // tracker from fighting the goto for the duration; when
        // it expires, the tracker resumes (and will pull the head
        // back to the user's face — accept that as the intended
        // behaviour, because the user asked for an explicit one-
        // shot look, not a permanent gaze).
        await MainActor.run {
            services.transitioningUntil =
                Date().addingTimeInterval(Self.durationS + 0.2)
        }

        do {
            try await services.robotLink.goto(
                headPose: target,
                antennas: nil,
                bodyYaw: nil,
                durationS: Self.durationS,
                interpolation: .minjerk
            )
        } catch {
            return .object([
                "ok": .bool(false),
                "error": .string("\(error)"),
                "yaw_target_rad": .number(yawTarget),
                "pitch_target_rad": .number(pitchTarget),
            ])
        }

        return .object([
            "ok": .bool(true),
            "x": .number(x),
            "y": .number(y),
            "aspect_ratio": .number(aspect),
            "yaw_delta_rad": .number(yawDelta),
            "pitch_delta_rad": .number(pitchDelta),
            "yaw_target_rad": .number(yawTarget),
            "pitch_target_rad": .number(pitchTarget),
            "description": .string(description),
        ])
    }
}
