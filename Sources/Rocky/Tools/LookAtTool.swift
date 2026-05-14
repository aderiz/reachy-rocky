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

    /// Effective horizontal FOV of the camera frame the brain
    /// actually sees. This is NOT the raw camera spec (the IMX708
    /// lens is wider) — it's the calibrated value `MacFaceTracker`
    /// uses to convert image-pixel offsets into head-pose deltas,
    /// validated against the live face-tracker behaviour. The
    /// previous 120° value commanded ~2× too much rotation,
    /// overshooting every target the brain asked for.
    static let horizontalFOVRad: Double = 65.0 * .pi / 180.0

    /// Effective vertical FOV, same source as the horizontal value.
    /// (Don't derive from aspect ratio — the cropped/scaled frame
    /// the brain sees doesn't have the same VFOV as a pure aspect
    /// scaling of the raw sensor would imply.)
    static let verticalFOVRad: Double = 39.0 * .pi / 180.0

    /// Default frame aspect ratio when the brain doesn't tell us
    /// what it saw. Kept for the tool's `aspect_ratio` parameter so
    /// LLMs that pass it don't break — the value is now ignored in
    /// favour of the calibrated VFOV constant above.
    static let defaultAspectRatio: Double = 16.0 / 9.0

    /// Minjerk duration for the look-at goto. 1.5 s is long enough
    /// for the body_yaw joint (slower dynamics than head) to actually
    /// reach its commanded target — 0.7 s only got the body 40 % of
    /// the way there in practice. Still feels responsive ("look at
    /// that" → 1.5 s smooth swing is natural, not slow).
    static let durationS: Double = 1.5

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
                // Small LLMs (Gemma 4, some Qwen variants) emit
                // numeric tool args as STRINGS ("0.9" not 0.9).
                // `asNumber` only matches `.number(_)` so we'd
                // silently default to 0.5 → zero delta → no
                // movement. Accept either form here so a stringified
                // 0.9 still rotates the head/body toward x=0.9.
                func num(_ key: String, default def: Double) -> Double {
                    guard let v = args.asObject?[key] else { return def }
                    if let n = v.asNumber { return n }
                    if let s = v.asString, let d = Double(s) { return d }
                    return def
                }
                let xRaw = num("x", default: 0.5)
                let yRaw = num("y", default: 0.5)
                let aspect = num("aspect_ratio", default: Self.defaultAspectRatio)
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

    /// Comfortable head-yaw range — beyond this the rotation is
    /// pushed onto the body so the neck doesn't crank to extremes.
    /// Cap at 30° because anything more reads as a neck twist; the
    /// body should be doing the bulk of large lateral looks.
    static let headYawComfortableMax: Double = 30.0 * .pi / 180.0

    /// Hard cap on the body-yaw output from a look-at command. The
    /// hardware limit is ±160 ° (`SafetyLimits.bodyYawMax`) but that
    /// was sized for one-shot recorded moves. For a look-at, ±90 °
    /// is the most we ever want — beyond that, the user is almost
    /// behind the bot and a `go_home` makes more sense than spinning
    /// further. Without this cap, overflow from a giant head delta
    /// was twisting the body to ±152 ° (nearly facing backwards).
    static let bodyYawComfortableMax: Double = 90.0 * .pi / 180.0

    /// The actual goto. Pulled out into a static function so the
    /// tool handler closure stays readable + so tests can drive
    /// the math without the registry.
    static func performLook(
        x: Double, y: Double, aspect: Double,
        description: String,
        services: AppServices
    ) async -> JSONValue {
        // Use the calibrated VFOV constant (matches MacFaceTracker).
        // The `aspect` parameter is accepted from the brain for
        // backward compat but ignored — the cropped/scaled frame's
        // actual FOV doesn't follow simple aspect-ratio scaling of
        // the raw sensor's HFOV.
        _ = aspect
        let vfov = Self.verticalFOVRad

        // Image-space → angle deltas.
        //
        // **Yaw sign**: an object at x=0.82 (right side of the
        // image) needs the camera to turn RIGHT. The daemon's
        // `head_pose.yaw` convention is "positive = left" (matches
        // the `look_at` tool's documented sign), so turning RIGHT
        // means DECREASING yaw — `yawDelta` must be NEGATIVE for
        // positive x-offsets. The previous version used
        // `(x - 0.5)` and was turning the head the wrong way (the
        // `MacFaceTracker.swift:466` controller uses `-un * hfov/2`
        // for the same reason — that one's been correct all along).
        //
        // **Pitch sign**: y is positive downward in image space;
        // Reachy Mini's head pitch is positive downward too (head
        // tilts forward), so the sign is preserved verbatim.
        let yawDelta = -(x - 0.5) * Self.horizontalFOVRad
        let pitchDelta = (y - 0.5) * vfov

        // Read current pose + body yaw. State-stream lag at cold
        // start is the only failure mode; in that case we just
        // command the absolute requested angle.
        let (currentPose, currentBodyYaw) = await MainActor.run {
            (services.lastRobotState?.headPose,
             services.lastRobotState?.bodyYaw)
        }
        let baseYaw = currentPose?.yaw ?? 0
        let basePitch = currentPose?.pitch ?? 0
        let baseRoll = currentPose?.roll ?? 0
        let baseBody = currentBodyYaw ?? 0

        // **Head + body split, body-heavy.** The user wants the
        // whole bot to turn toward the target, not just the head
        // twisting. Reachy Mini can rotate body (±160°) and head
        // (±180°); we give the BODY 65 % of the yaw delta and the
        // HEAD the remaining 35 %. That makes large rotations read
        // as "Rocky turns to face the whiteboard" rather than "Rocky's
        // head cranes over while the body stays still."
        //
        // For small deltas (< ~12 ° in total), this still feels
        // natural — the body shifts slightly and the head does a
        // little look. For large deltas (object near frame edge),
        // the body does most of the work and the head fine-tunes.
        //
        // If the head's share would exceed its comfortable range
        // (±headYawComfortableMax = 30 °), the overflow is pushed
        // to the body so the neck doesn't crank past 30 °.
        let desiredCameraYaw = (baseYaw + baseBody) + yawDelta
        let bodyShare = 0.65
        let headShare = 1.0 - bodyShare
        let headRequested = baseYaw + yawDelta * headShare
        let bodyRequested = baseBody + yawDelta * bodyShare

        let yawHeadTarget: Double
        let yawBodyTarget: Double
        if abs(headRequested) > Self.headYawComfortableMax {
            // Head exceeds comfort cap — pin it to the cap, push
            // overflow to body.
            let cappedHead = headRequested > 0
                ? Self.headYawComfortableMax
                : -Self.headYawComfortableMax
            let overflow = headRequested - cappedHead
            yawHeadTarget = SafetyLimits.clamp(
                cappedHead, to: Self.headYawComfortableMax
            )
            yawBodyTarget = SafetyLimits.clamp(
                bodyRequested + overflow, to: Self.bodyYawComfortableMax
            )
        } else {
            yawHeadTarget = SafetyLimits.clamp(
                headRequested, to: Self.headYawComfortableMax
            )
            yawBodyTarget = SafetyLimits.clamp(
                bodyRequested, to: Self.bodyYawComfortableMax
            )
        }
        let pitchTarget = SafetyLimits.clamp(
            basePitch + pitchDelta, to: SafetyLimits.headPitchMax
        )

        let headTarget = RPYPose(
            roll: baseRoll, pitch: pitchTarget, yaw: yawHeadTarget
        )

        // **Holding the look** requires THREE things, not just one:
        //
        //   1. Stop the face tracker pushing new targets:
        //      `macFaceTracker.setEnabled(false)` flips `userEnabled`
        //      false so the tracker's tick loop no longer calls
        //      `streamer.update(...)`.
        //   2. Overwrite the streamer's `latest` with the look-at
        //      pose. THIS is the bug the previous patch missed —
        //      `TargetStreamer.tick()` re-sends `latest` at 50 Hz
        //      forever. The face tracker had stamped `latest = "look
        //      at user"` before our goto; after the goto completes,
        //      the streamer immediately re-pushes that stale target
        //      and the head drifts back. Stamping `latest` with the
        //      look-at pose makes the streamer hold the look.
        //   3. Suppress the streamer briefly so the goto isn't
        //      contested by simultaneous set_target updates (the
        //      daemon ignores set_target during a goto anyway, but
        //      keeping `transitioningUntil` set makes the intent
        //      clear for downstream gates).
        await services.macFaceTracker.setEnabled(false)
        let holdTarget = MotionTarget(
            headPose: headTarget,
            antennas: nil,
            bodyYaw: yawBodyTarget
        )
        await services.targetStreamer.update(holdTarget, source: .tool)
        await MainActor.run {
            services.transitioningUntil =
                Date().addingTimeInterval(Self.durationS + 0.2)
        }

        do {
            try await services.motionGuard.goto(
                headPose: headTarget,
                antennas: nil,
                bodyYaw: yawBodyTarget,
                durationS: Self.durationS,
                interpolation: .minjerk
            )
        } catch {
            return .object([
                "ok": .bool(false),
                "error": .string("\(error)"),
                "head_yaw_target_rad": .number(yawHeadTarget),
                "body_yaw_target_rad": .number(yawBodyTarget),
                "pitch_target_rad": .number(pitchTarget),
            ])
        }

        return .object([
            "ok": .bool(true),
            "next_step": .string(
                "Head and body have turned. The CURRENT camera frame "
                + "is now stale. End this round (do NOT call "
                + "look_at_object again here). The next user turn "
                + "OR the next assistant round will show a fresh "
                + "frame — re-examine the target's image position "
                + "THEN decide if another look_at_object is needed."
            ),
            "x": .number(x),
            "y": .number(y),
            "aspect_ratio": .number(aspect),
            "yaw_delta_rad": .number(yawDelta),
            "pitch_delta_rad": .number(pitchDelta),
            "head_yaw_target_rad": .number(yawHeadTarget),
            "body_yaw_target_rad": .number(yawBodyTarget),
            "pitch_target_rad": .number(pitchTarget),
            "camera_world_yaw_rad": .number(desiredCameraYaw),
            "description": .string(description),
        ])
    }
}
