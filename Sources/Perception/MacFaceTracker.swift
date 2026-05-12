import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Vision                  // Apple's Vision framework — face detection
import RockyKit
import RobotLink
import RockyVision             // Our Vision module (renamed to avoid collision)
import Telemetry

/// On-Mac face tracker. Pulls JPEG frames from `RobotCameraService.frames`,
/// runs `VNDetectFaceRectanglesRequest`, converts the largest face's bbox
/// into a world-frame yaw/pitch target, smooths it with EMA + a critically-
/// damped 50 Hz controller, and forwards the smoothed pose into a
/// `TargetStreamer` so the robot actually moves.
///
/// This replaces the synthetic Lissajous targets coming from the Python
/// face-tracker sidecar — the robot follows your face instead of a fake
/// pattern.
public actor MacFaceTracker {
    public struct Config: Sendable {
        /// Reachy Mini's wide-angle camera FOV.
        public var hfovDeg: Double = 65.0
        public var vfovDeg: Double = 39.0
        /// EMA on the world-frame target. Lower = more responsive.
        /// 0.25 weights the new detection at 75% — fast follow without
        /// reacting to per-frame jitter.
        public var emaAlpha: Double = 0.25
        /// Critical-damper natural frequency (rad/s). 4.0 → ~1.5 s settle
        /// (5%), visibly responsive but no snap. Single tweak from the
        /// previous 6.0 which was felt as too aggressive. Per robot-safety
        /// rule we change one knob at a time; if this is still too hot,
        /// next pass tightens the speed cap.
        public var damperOmega: Double = 4.0
        /// Drop detections smaller than this fraction of the frame.
        public var minBboxNorm: Double = 0.05
        /// After this idle window with no detections, decay world target home.
        public var idleTimeoutS: Double = 1.5
        /// Per-second decay rate while idle.
        public var decayPerSecond: Double = 0.6
        /// Tick frequency for the command loop.
        public var commandHz: Double = 50.0
        /// Max angular speed the damper output is allowed to change per
        /// tick (rad/s). 1.2 ≈ 69°/s, distinctly slower than a casual
        /// human head turn (~60–150°/s). The user reported the head
        /// "colliding and moving fast"; capping velocity harder gives
        /// the daemon more time to plan motor moves and prevents the
        /// controller from driving past mechanical limits.
        public var maxSpeedRadPerS: Double = 1.2  // ~69°/s

        // Body-follow controller. Reachy Mini has a body_yaw joint that
        // rotates the whole assembly under the head; a gentle, lagging
        // body turn alongside the head reads as natural attention
        // shifting. The body uses an independent damper so it eases in
        // behind the head's faster motion rather than rigidly mirroring.

        /// Fraction of head-yaw the body tries to match. 0.35 = body
        /// rotates a third as far as the head — readable but not
        /// rigid-coupled.
        public var bodyFollowFactor: Double = 0.35
        /// Slower than head's `damperOmega` so the body lags behind.
        public var bodyDamperOmega: Double = 2.5
        /// 0.7 rad/s ≈ 40°/s — slower still than the head's cap.
        public var bodyMaxSpeedRadPerS: Double = 0.7

        // Idle look-around — kicks in after `idleTimeoutS` without a
        // face. Slow Lissajous-y pattern so the bot feels alive
        // rather than going completely still.
        public var idleYawAmplitude: Double = 0.30      // ~17°
        public var idlePitchAmplitude: Double = 0.05    // ~3°
        public var idleYawPeriodS: Double = 30.0
        public var idlePitchPeriodS: Double = 18.0

        // Antenna twitches — independent Poisson-process triggers per
        // antenna so the timing is genuinely random (exponentially-
        // distributed gaps), not a regular tempo. Mean rate ~0.10/s
        // per antenna ≈ one twitch every ~10 s on average, with two
        // antennas combined that's noticeable life-signs without
        // being constantly twitchy.
        public var antennaTwitchRatePerS: Double = 0.10
        // ~0.12 rad ≈ 7° — gentler than the old 0.20 rad (~11°)
        // step which was visibly flicking the motors.
        public var antennaTwitchAmplitude: Double = 0.12
        public var antennaTwitchMinHold: Double = 0.18
        public var antennaTwitchMaxHold: Double = 0.55
        // Smoothing time-constants for the eased ramp toward the
        // random target on trigger, and back to zero after release.
        // ~80 ms in / 150 ms out. Eliminates the step-change "flick"
        // that motors couldn't track at one frame's slew rate.
        public var antennaEaseInTau: Double = 0.08
        public var antennaEaseOutTau: Double = 0.15
        // Output quantisation for the antenna setpoint sent to the
        // bot. 0.02 rad ≈ 1.15° per step. Snapping the 50 Hz stream
        // to a coarse grid means consecutive ticks emit the *same*
        // value during the entire hold phase (no per-frame
        // floating-point drift), and the ease-in / ease-out
        // present as 5–7 discrete steps instead of 30 micro-
        // adjustments. Eliminates the bot motor's high-frequency
        // chase / vibration without changing the visual envelope
        // of the twitch.
        public var antennaQuantizeStepRad: Double = 0.02

        // Antenna rest position — must NOT be 0 rad. The bot's
        // antenna motors mechanically resonate / shake when held at
        // vertical; Pollen's own daemon documents this with
        // INIT_ANTENNAS_JOINT_POSITIONS = [-0.1745, 0.1745] "~10°
        // offset to reduce shaking at vertical". Twitches deviate
        // from this rest position and return to it (not to zero).
        // Sign convention matches the daemon: left negative, right
        // positive (both tilt outward from the bot's centreline).
        public var antennaLeftRestRad: Double = -0.1745
        public var antennaRightRestRad: Double =  0.1745

        public init() {}
    }

    public struct Detection: Sendable, Equatable {
        public let bbox: CGRect
        public let confidence: Double
        public let frameWidth: Int
        public let frameHeight: Int
        /// Name of the recognised person, if the face matches an enrolled
        /// entry in `FaceLibrary` within the accept threshold. Nil while
        /// the face is unknown or while identification hasn't run yet.
        public let identity: String?
        /// Distance to the matched sample (smaller = better). Surfaced for
        /// debugging / display only.
        public let identityDistance: Double?
        /// Closest enrolled name regardless of the accept threshold —
        /// surfaced so the user can see the live distance and tune the
        /// threshold from Settings without guessing.
        public let closestName: String?
        public let closestDistance: Double?
    }

    /// Live stream of detections (for the Vision card overlay).
    public nonisolated let detections: AsyncStream<Detection>
    private let detectionsContinuation: AsyncStream<Detection>.Continuation

    /// Per-identification-cycle set of names that are currently
    /// recognised in view — emitted whenever the set CHANGES so the
    /// greeting state machine can fire for non-primary faces without
    /// the head ever following them.
    public nonisolated let identitiesInView: AsyncStream<Set<String>>
    private let identitiesContinuation: AsyncStream<Set<String>>.Continuation

    /// Live stream of smoothed world-frame yaw/pitch targets.
    public nonisolated let targets: AsyncStream<(yawRad: Double, pitchRad: Double, decay: Bool)>
    private let targetsContinuation: AsyncStream<(yawRad: Double, pitchRad: Double, decay: Bool)>.Continuation

    private let logBus: LogBus
    private var config: Config
    private var streamer: TargetStreamer?
    private var library: FaceLibrary?

    // EMA state (world-frame)
    private var emaYaw: Double = 0
    private var emaPitch: Double = 0
    private var emaInitialized: Bool = false

    // Identification state — last successful match, with TTL so a stale
    // identity doesn't haunt the Detection forever.
    private var lastIdentityName: String?
    private var lastIdentityDistance: Double?
    private var lastIdentityTs: Date?
    private let identityTTL: TimeInterval = 3.0
    // Closest match is updated independently — even when below threshold —
    // so the UI can show the user "best: Alice 0.92" while they tune the
    // accept threshold.
    private var lastClosestName: String?
    private var lastClosestDistance: Double?

    // Primary-face tracking. When the library has a person flagged as
    // primary, we track ONLY that face. If primary isn't in view we
    // emit no detection so the controller decays toward home rather
    // than chasing whoever else happens to be largest.
    private var cachedPrimaryName: String?
    private var lastPrimaryBbox: CGRect?
    private var lastPrimaryBboxTs: Date?
    /// Hold the last primary lock for this long before falling back to
    /// "no primary in view". 5 s is generous enough that brief
    /// occlusions or fast head turns don't break the lock and cause the
    /// controller to flicker between "track primary" and "decay home"
    /// (which manifested as jerky tracking).
    private let primaryFollowTTL: TimeInterval = 5.0

    // Names recognised in the current frame's identification cycle.
    // Emitted on the `identitiesInView` stream when it changes so the
    // greeting state machine can fire for any face in view, primary
    // or not.
    private var lastIdentitiesInView: Set<String> = []
    private var frameCounter: Int = 0
    /// Run identification every Nth ingested frame. 6 → ~5 Hz at 30 FPS,
    /// which is plenty for "who is this" while the per-frame detection
    /// path stays fast.
    private let identifyEvery: Int = 6
    /// Set to true while an async identify task is running so we don't
    /// fan out parallel identifications.
    private var identifying: Bool = false

    // CriticalDamper state per-axis
    private var dampYawX: Double = 0;   private var dampYawV: Double = 0
    private var dampPitchX: Double = 0; private var dampPitchV: Double = 0
    private var dampBodyYawX: Double = 0; private var dampBodyYawV: Double = 0

    // Antenna twitch state. Each antenna runs an independent Poisson
    // process — every command tick (50 Hz) it gets a small probability
    // of firing. Exponentially-distributed gaps mean the rhythm has
    // no perceptible period: bursts, lulls, asymmetric movement —
    // looks and feels random instead of clockwork.
    //
    // Rest position is ±0.1745 rad (~10°), not 0, because the motors
    // physically vibrate when held at vertical. Cmd/target are
    // absolute angles in the daemon's coordinate frame; both are
    // initialised to the rest position so the very first emitted
    // setpoint already lands at the safe offset.
    private lazy var antennaLeftCmd: Double = config.antennaLeftRestRad
    private lazy var antennaRightCmd: Double = config.antennaRightRestRad
    private var leftTwitchReleaseAt: Date?
    private var rightTwitchReleaseAt: Date?
    /// Target value each antenna eases toward. Set to (rest + random
    /// amplitude) on trigger; reset to the rest position on release.
    /// The actual commanded value (`antenna{Left,Right}Cmd`) follows
    /// via a critically-damped ramp.
    private lazy var antennaLeftTarget: Double = config.antennaLeftRestRad
    private lazy var antennaRightTarget: Double = config.antennaRightRestRad

    private var lastDetectionTs: Date?
    /// Suspends pushing to `streamer` while the daemon plays a primary
    /// move (wake_up / goto_sleep / emotion). Caller toggles this.
    private var streamerSuppressed: Bool = false
    private var userEnabled: Bool = true

    private var detectorTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?

    public init(logBus: LogBus, config: Config = Config()) {
        self.logBus = logBus
        self.config = config
        var dc: AsyncStream<Detection>.Continuation!
        self.detections = AsyncStream<Detection>(
            bufferingPolicy: .bufferingNewest(8)
        ) { c in dc = c }
        self.detectionsContinuation = dc

        var tc: AsyncStream<(yawRad: Double, pitchRad: Double, decay: Bool)>.Continuation!
        self.targets = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c in tc = c }
        self.targetsContinuation = tc

        var ic: AsyncStream<Set<String>>.Continuation!
        self.identitiesInView = AsyncStream(
            bufferingPolicy: .bufferingNewest(8)
        ) { c in ic = c }
        self.identitiesContinuation = ic
    }

    public func setStreamer(_ s: TargetStreamer) {
        self.streamer = s
    }

    public func setLibrary(_ lib: FaceLibrary) {
        self.library = lib
    }

    /// Pause/unpause pushes to the streamer (used during recorded moves
    /// like wake_up so we don't fight a primary animation). Transient
    /// — set by the in-flight-move watch loop in AppServices and
    /// expected to flip back when the move finishes.
    public func setStreamerSuppressed(_ suppressed: Bool) {
        self.streamerSuppressed = suppressed
    }

    /// User-controlled enable / disable. Sticky — set by the
    /// `pause_face_tracking` / `resume_face_tracking` tools and the
    /// menu-bar / Settings toggle. Composes with `streamerSuppressed`:
    /// the streamer only receives target updates when **both**
    /// `userEnabled == true` AND `streamerSuppressed == false`.
    public func setEnabled(_ enabled: Bool) {
        self.userEnabled = enabled
    }

    /// Start the 50 Hz command tick. Caller pushes frames in via `ingest(_:)`.
    public func start() {
        commandTask?.cancel()
        commandTask = Task { [weak self] in
            await self?.commandLoop()
        }
    }

    public func stop() {
        commandTask?.cancel(); commandTask = nil
    }

    /// Public entry point — caller (AppServices) owns the camera frame
    /// stream and forwards each frame here so we don't fight the UI mirror
    /// for the single-consumer AsyncStream.
    public func ingestFrame(_ frame: RobotCameraService.Frame) async {
        await ingest(frame)
    }

    // MARK: - Ingest

    private func ingest(_ frame: RobotCameraService.Frame) async {
        // Decode JPEG -> CGImage.
        guard let provider = CGDataProvider(data: frame.jpeg as CFData),
              let cgImage = CGImage(
                jpegDataProviderSource: provider,
                decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return }

        // Run Vision face detection. Modern (macOS 15+) async Swift API.
        // Fully-qualified to avoid Xcode index confusion with our local
        // `RockyVision` module which shares the same name root.
        let observations: [Vision.FaceObservation]
        do {
            let request = Vision.DetectFaceRectanglesRequest()
            observations = try await request.perform(on: cgImage)
        } catch {
            await logBus.publish(.error(
                scope: "mac-face-tracker", message: "VN perform: \(error)",
                recoverable: true
            ))
            return
        }

        // Build pixel-rect candidates sorted by area desc, gated by
        // minBboxNorm. Smaller faces are dropped early so neither the
        // tracker nor the identifier waste cycles on them.
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        let allCandidates: [(observation: Vision.FaceObservation, pixelRect: CGRect)] =
            observations
                .map { obs -> (observation: Vision.FaceObservation, pixelRect: CGRect) in
                    let bb = obs.boundingBox.cgRect
                    let rect = CGRect(
                        x: bb.origin.x * imgW,
                        y: (1.0 - bb.origin.y - bb.size.height) * imgH,
                        width: bb.size.width * imgW,
                        height: bb.size.height * imgH
                    )
                    return (obs, rect)
                }
                .filter {
                    let n = max($0.pixelRect.width / imgW, $0.pixelRect.height / imgH)
                    return n >= config.minBboxNorm
                }
                .sorted { (a, b) in
                    a.pixelRect.width * a.pixelRect.height
                  > b.pixelRect.width * b.pixelRect.height
                }

        guard !allCandidates.isEmpty else {
            // No face this frame; controller will start decaying after
            // idleTimeoutS without further detections.
            return
        }

        // ALWAYS use the largest face. Earlier attempts at "primary
        // only" tracking (which could withhold detections) starved the
        // controller and produced the jerky pattern you saw.
        let largest = allCandidates[0].observation
        let pixelRect = allCandidates[0].pixelRect

        // Decay stale identity past TTL.
        if let ts = lastIdentityTs,
           Date().timeIntervalSince(ts) > identityTTL {
            lastIdentityName = nil
            lastIdentityDistance = nil
        }

        let det = Detection(
            bbox: pixelRect,
            confidence: Double(largest.confidence),
            frameWidth: cgImage.width,
            frameHeight: cgImage.height,
            identity: lastIdentityName,
            identityDistance: lastIdentityDistance,
            closestName: lastClosestName,
            closestDistance: lastClosestDistance
        )
        detectionsContinuation.yield(det)

        // Single-face identification path — runs every Nth frame on
        // ONLY the largest face's crop. The previous "top-3" version
        // tripled the feature-print work per cycle, which intermittently
        // held the FaceTracker actor and starved the 50 Hz commandLoop
        // of regular `dt` ticks. With irregular dt, the damper's
        // integration produced cap-speed steps that read as aggressive
        // jerks. Going back to one print per cycle restores the original
        // smooth dynamic.
        frameCounter &+= 1
        if !identifying,
           let lib = library,
           frameCounter % identifyEvery == 0 {
            identifying = true
            let cropRect = pixelRect.insetBy(
                dx: -pixelRect.width * 0.25,
                dy: -pixelRect.height * 0.25
            ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
            if let cropped = cgImage.cropping(to: cropRect) {
                Task { [weak self] in
                    await self?.runSingleIdentification(
                        crop: cropped, library: lib
                    )
                }
            } else {
                identifying = false
            }
        }

        // Convert centroid → camera-frame angle → world-frame target.
        // Use the DAMPER's current commanded position as the world-frame
        // baseline (not a lagged state-stream sample). This removes the
        // ~100 ms feedback delay that was making the loop oscillate.
        let cxD: Double = Double(pixelRect.midX)
        let cyD: Double = Double(pixelRect.midY)
        let imgWD: Double = Double(imgW)
        let imgHD: Double = Double(imgH)
        let un: Double = (cxD / imgWD) * 2.0 - 1.0
        let vn: Double = (cyD / imgHD) * 2.0 - 1.0
        let hfovRad: Double = config.hfovDeg * Double.pi / 180.0
        let vfovRad: Double = config.vfovDeg * Double.pi / 180.0
        let yawOffset: Double = -un * hfovRad / 2.0
        let pitchOffset: Double = vn * vfovRad / 2.0
        let worldYaw = dampYawX + yawOffset
        let worldPitch = dampPitchX + pitchOffset

        // EMA-smooth the world target.
        if emaInitialized {
            emaYaw = config.emaAlpha * emaYaw + (1.0 - config.emaAlpha) * worldYaw
            emaPitch = config.emaAlpha * emaPitch + (1.0 - config.emaAlpha) * worldPitch
        } else {
            emaYaw = worldYaw; emaPitch = worldPitch
            emaInitialized = true
        }
        lastDetectionTs = Date()
    }

    // MARK: - 50 Hz command loop

    private func commandLoop() async {
        let periodNs = UInt64(1_000_000_000 / config.commandHz)
        var lastTick = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: periodNs)
            let now = ContinuousClock.now
            let dtRaw = Double((now - lastTick).components.attoseconds) / 1.0e18
                      + Double((now - lastTick).components.seconds)
            let dt = max(0.0, min(0.05, dtRaw))   // clamp to avoid huge jumps
            lastTick = now

            let decay = await self.decayIfIdle(dt: dt)

            let targetYaw = emaInitialized ? emaYaw : 0.0
            let targetPitch = emaInitialized ? emaPitch : 0.0

            // Critical damper, semi-implicit Euler:
            //   v <- v + dt*(-2*omega*v - omega^2 * (x - r))
            //   x <- x + dt*v
            let w = config.damperOmega
            let aY = -2.0 * w * dampYawV - (w * w) * (dampYawX - targetYaw)
            dampYawV += dt * aY
            // Speed cap so any single-tick jump from a target snap is bounded.
            if config.maxSpeedRadPerS > 0 {
                dampYawV = max(-config.maxSpeedRadPerS,
                               min(config.maxSpeedRadPerS, dampYawV))
            }
            dampYawX += dt * dampYawV
            let aP = -2.0 * w * dampPitchV - (w * w) * (dampPitchX - targetPitch)
            dampPitchV += dt * aP
            if config.maxSpeedRadPerS > 0 {
                dampPitchV = max(-config.maxSpeedRadPerS,
                                 min(config.maxSpeedRadPerS, dampPitchV))
            }
            dampPitchX += dt * dampPitchV

            let yawClamped = SafetyLimits.clamp(dampYawX, to: SafetyLimits.headYawMax)
            let pitchClamped = SafetyLimits.clamp(dampPitchX, to: SafetyLimits.headPitchMax)

            // Body-yaw follow. Independent damper, slower omega + lower
            // speed cap, target = head's commanded yaw scaled by the
            // follow factor. Naturally decays home with the head when
            // the face leaves view (target shrinks toward 0).
            let bodyTarget = dampYawX * config.bodyFollowFactor
            let wB = config.bodyDamperOmega
            let aB = -2.0 * wB * dampBodyYawV
                   - (wB * wB) * (dampBodyYawX - bodyTarget)
            dampBodyYawV += dt * aB
            if config.bodyMaxSpeedRadPerS > 0 {
                dampBodyYawV = max(-config.bodyMaxSpeedRadPerS,
                                   min(config.bodyMaxSpeedRadPerS, dampBodyYawV))
            }
            dampBodyYawX += dt * dampBodyYawV
            let bodyClamped = SafetyLimits.clamp(
                dampBodyYawX, to: SafetyLimits.bodyYawMax
            )

            targetsContinuation.yield((yawClamped, pitchClamped, decay))

            // Push to streamer unless caller suppressed (e.g., during a
            // wake_up / goto_sleep recorded move). We always include
            // antennas so the twitch pattern animates regardless of
            // whether the head is actively tracking or idling.
            let antennas = tickAntennas(dt: dt)
            if let streamer, userEnabled, !streamerSuppressed {
                let pose = RPYPose(roll: 0, pitch: pitchClamped, yaw: yawClamped)
                await streamer.update(
                    .init(headPose: pose, antennas: antennas, bodyYaw: bodyClamped),
                    source: .face
                )
            }
        }
    }

    // MARK: - Tracking + identification helpers

    /// Pick the face Rocky should orient toward this frame.
    /// - With a primary set: the face whose pixel bbox best overlaps
    ///   the most-recent primary bbox (within TTL). If none overlap
    ///   enough, we return nil so the controller decays home — we do
    ///   NOT chase another person who happens to be largest.
    /// - Without a primary: the largest face (original behaviour).
    private func pickTrackingCandidate(
        from candidates: [(observation: Vision.FaceObservation, pixelRect: CGRect)]
    ) -> (observation: Vision.FaceObservation, pixelRect: CGRect)? {
        // ALWAYS pick the largest face if any are present. The previous
        // attempt at strict "primary only" tracking returned nil when
        // the primary's bbox didn't match a current-frame face; that
        // starved the controller of detections, the EMA stalled, and
        // when the next identification cycle re-locked the primary the
        // EMA snapped — which the user (correctly) called jerky.
        //
        // The greeting state machine still differentiates by identity
        // via `identitiesInView`, so non-primary recognised faces still
        // get greeted. We just no longer try to withhold tracking based
        // on identity — the controller needs continuous input.
        return candidates.first
    }

    /// Single-face identification: feature-print just the largest face's
    /// crop, look up its closest enrolled match. Greeting still fires
    /// for the largest face's identity via the AppServices-side handler
    /// that watches `det.identity`. Sticking to one print per cycle
    /// keeps the `FaceTracker` actor free for the 50 Hz commandLoop.
    private func runSingleIdentification(
        crop: CGImage, library: FaceLibrary
    ) async {
        defer { identifying = false }
        guard let observation = await library.generatePrint(cgImage: crop)
        else { return }
        guard let closest = await library.closestMatch(observation)
        else { return }
        lastClosestName = closest.person.name
        lastClosestDistance = closest.distance
        let threshold = await library.acceptThreshold
        if closest.distance <= threshold {
            lastIdentityName = closest.person.name
            lastIdentityDistance = closest.distance
            lastIdentityTs = Date()
            // Also publish to identitiesInView so the greeting state
            // machine still fires.
            let newSet: Set<String> = [closest.person.name]
            if newSet != lastIdentitiesInView {
                lastIdentitiesInView = newSet
                identitiesContinuation.yield(newSet)
            }
        } else {
            // Largest face is unknown — clear in-view set if it had a
            // name, so the next visible enrolled face triggers a fresh
            // greeting.
            if !lastIdentitiesInView.isEmpty {
                lastIdentitiesInView = []
                identitiesContinuation.yield([])
            }
        }
    }

    /// Idle look-around: when no face has been seen for `idleTimeoutS`,
    /// drive the EMA target along a slow Lissajous-style pattern
    /// instead of decaying to neutral. The bot feels alive — head pans
    /// gently and pitches up/down at a different period so the motion
    /// never repeats exactly. The damper still smooths everything.
    private func decayIfIdle(dt: Double) async -> Bool {
        guard let last = lastDetectionTs else { return false }
        let elapsed = Date().timeIntervalSince(last)
        if elapsed < config.idleTimeoutS { return false }
        let t = Date().timeIntervalSince1970
        emaYaw = config.idleYawAmplitude
            * sin(2.0 * .pi * t / config.idleYawPeriodS)
        emaPitch = config.idlePitchAmplitude
            * sin(2.0 * .pi * t / config.idlePitchPeriodS)
        return true
    }

    /// Updates `antennaLeftCmd` / `antennaRightCmd` for the current
    /// tick. Each antenna runs an independent Poisson trigger — every
    /// tick has probability `dt * rate` of firing — so the inter-
    /// twitch gaps are exponentially distributed and the pattern has
    /// no perceptible rhythm.
    ///
    /// Output is quantised to `config.antennaQuantizeStepRad` (0.02
    /// rad ≈ 1°) before going on the wire. The internal `cmd` state
    /// stays high-precision so the easing model is unaffected, but
    /// the 50 Hz set_target stream emits identical quantised values
    /// across most consecutive ticks — including the entire hold
    /// phase, where the bot's motor sees the *exact same* setpoint
    /// 25 times a second instead of a chasing target with
    /// per-frame floating-point drift. Eliminates the
    /// high-frequency motor vibration the unquantised stream
    /// produced on the antennas' low-inertia motors.
    private func tickAntennas(dt: Double) -> Antennas {
        let now = Date()
        antennaLeftCmd = updateOneAntenna(
            cmd: antennaLeftCmd,
            target: &antennaLeftTarget,
            releaseAt: &leftTwitchReleaseAt,
            rest: config.antennaLeftRestRad,
            now: now, dt: dt
        )
        antennaRightCmd = updateOneAntenna(
            cmd: antennaRightCmd,
            target: &antennaRightTarget,
            releaseAt: &rightTwitchReleaseAt,
            rest: config.antennaRightRestRad,
            now: now, dt: dt
        )
        let step = config.antennaQuantizeStepRad
        let lq = (antennaLeftCmd / step).rounded() * step
        let rq = (antennaRightCmd / step).rounded() * step
        return Antennas(rightRad: rq, leftRad: lq)
    }

    /// Per-antenna twitch step using a critically-damped ramp instead
    /// of a step-change. Three pieces:
    /// 1. Poisson trigger (only when idle): pick a new `target`
    ///    amplitude in `[-A, +A]` and a hold duration. The trigger
    ///    sets the target *value*, not the commanded value — the
    ///    actual ramp happens in piece 3 below.
    /// 2. Release: once `releaseAt` is in the past, set `target = 0`
    ///    so the same ramp pulls the antenna back to neutral. When
    ///    both target and cmd are essentially zero, clear releaseAt
    ///    and let the next trigger fire.
    /// 3. Ramp: every tick, ease `cmd` toward `target` exponentially.
    ///    Time constants differ for in (~80 ms) vs. out (~150 ms);
    ///    in is tighter so twitches register cleanly, out is gentler
    ///    so the antenna settles without a snap. `dt/τ` clamped to
    ///    1.0 so a long stalled frame can't overshoot.
    private func updateOneAntenna(
        cmd: Double,
        target: inout Double,
        releaseAt: inout Date?,
        rest: Double,
        now: Date, dt: Double
    ) -> Double {
        // 1. Maybe fire a new twitch. Target is `rest + delta`
        //    where delta is uniform in [-amplitude, +amplitude];
        //    cmd eases toward that absolute target.
        if releaseAt == nil {
            let triggerProb = dt * config.antennaTwitchRatePerS
            if Double.random(in: 0...1) < triggerProb {
                let delta = Double.random(
                    in: -config.antennaTwitchAmplitude
                       ... config.antennaTwitchAmplitude
                )
                target = rest + delta
                let hold = Double.random(
                    in: config.antennaTwitchMinHold
                      ... config.antennaTwitchMaxHold
                )
                releaseAt = now.addingTimeInterval(hold)
            }
        }
        // 2. Release: return target to rest once the hold expires.
        //    The ramp below carries cmd home. CRITICAL: rest must
        //    NOT be 0 — the motors mechanically vibrate at 0 rad.
        if let release = releaseAt, now >= release, target != rest {
            target = rest
        }
        // 3. Ease cmd toward target. Different tau for in (departure
        //    from rest) vs out (return to rest), keyed on whether
        //    we're moving toward or away from the rest position.
        let movingTowardRest = abs(target - rest) < abs(cmd - rest)
        let tau = movingTowardRest
            ? config.antennaEaseOutTau
            : config.antennaEaseInTau
        let alpha = min(1.0, max(0.0, dt / max(tau, 0.001)))
        var c = cmd + alpha * (target - cmd)
        // Tidy up when fully decayed back to rest: clear releaseAt so
        // the antenna is eligible to twitch again.
        if releaseAt != nil, target == rest, abs(c - rest) < 1e-3 {
            c = rest
            releaseAt = nil
        }
        return c
    }
}

private extension CGSize {
    var area: CGFloat { width * height }
}
