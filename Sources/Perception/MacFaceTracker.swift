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

    private var lastDetectionTs: Date?
    /// Suspends pushing to `streamer` while the daemon plays a primary
    /// move (wake_up / goto_sleep / emotion). Caller toggles this.
    private var streamerSuppressed: Bool = false

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
    /// like wake_up so we don't fight a primary animation).
    public func setStreamerSuppressed(_ suppressed: Bool) {
        self.streamerSuppressed = suppressed
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

            targetsContinuation.yield((yawClamped, pitchClamped, decay))

            // Push to streamer unless caller suppressed (e.g., during a
            // wake_up / goto_sleep recorded move).
            if let streamer, !streamerSuppressed {
                let pose = RPYPose(roll: 0, pitch: pitchClamped, yaw: yawClamped)
                await streamer.update(.init(headPose: pose), source: .face)
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

    private func decayIfIdle(dt: Double) async -> Bool {
        guard let last = lastDetectionTs else { return false }
        let elapsed = Date().timeIntervalSince(last)
        if elapsed < config.idleTimeoutS { return false }
        // Exponential decay toward zero.
        let factor = max(0.0, 1.0 - config.decayPerSecond * dt)
        emaYaw *= factor
        emaPitch *= factor
        return true
    }
}

private extension CGSize {
    var area: CGFloat { width * height }
}
