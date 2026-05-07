import Foundation
import CoreGraphics
import CoreImage
import ImageIO
@preconcurrency import Vision  // Apple's Vision framework — face detection
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
        /// World-frame target smoothing.
        public var emaAlpha: Double = 0.5
        /// Critical-damper natural frequency (rad/s). 3 → ~1.9 s settle.
        public var damperOmega: Double = 3.0
        /// Drop detections smaller than this fraction of the frame.
        public var minBboxNorm: Double = 0.05
        /// After this idle window with no detections, decay world target home.
        public var idleTimeoutS: Double = 1.5
        /// Per-second decay rate while idle.
        public var decayPerSecond: Double = 0.6
        /// Tick frequency for the command loop.
        public var commandHz: Double = 50.0

        public init() {}
    }

    public struct Detection: Sendable, Equatable {
        public let bbox: CGRect
        public let confidence: Double
        public let frameWidth: Int
        public let frameHeight: Int
    }

    /// Live stream of detections (for the Vision card overlay).
    public nonisolated let detections: AsyncStream<Detection>
    private let detectionsContinuation: AsyncStream<Detection>.Continuation

    /// Live stream of smoothed world-frame yaw/pitch targets.
    public nonisolated let targets: AsyncStream<(yawRad: Double, pitchRad: Double, decay: Bool)>
    private let targetsContinuation: AsyncStream<(yawRad: Double, pitchRad: Double, decay: Bool)>.Continuation

    private let logBus: LogBus
    private var config: Config
    private var streamer: TargetStreamer?

    // EMA state (world-frame)
    private var emaYaw: Double = 0
    private var emaPitch: Double = 0
    private var emaInitialized: Bool = false

    // CriticalDamper state per-axis
    private var dampYawX: Double = 0;   private var dampYawV: Double = 0
    private var dampPitchX: Double = 0; private var dampPitchV: Double = 0

    private var lastDetectionTs: Date?
    private var commandedYaw: Double = 0
    private var commandedPitch: Double = 0

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
    }

    public func setStreamer(_ s: TargetStreamer) {
        self.streamer = s
    }

    public func updateCommandedPose(yawRad: Double, pitchRad: Double) {
        self.commandedYaw = yawRad
        self.commandedPitch = pitchRad
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

        // Run Vision face detection. Modern (macOS 26+) async API.
        let observations: [FaceObservation]
        do {
            let request = DetectFaceRectanglesRequest()
            observations = try await request.perform(on: cgImage)
        } catch {
            await logBus.publish(.error(
                scope: "mac-face-tracker", message: "VN perform: \(error)",
                recoverable: true
            ))
            return
        }

        guard let largest = observations
            .max(by: { $0.boundingBox.cgRect.width * $0.boundingBox.cgRect.height
                     < $1.boundingBox.cgRect.width * $1.boundingBox.cgRect.height })
        else {
            // No face this frame; controller will start decaying after
            // idleTimeoutS without further detections.
            return
        }

        // boundingBox: NormalizedRect, BL origin in image-space.
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let bb = largest.boundingBox.cgRect
        let pixelRect = CGRect(
            x: bb.origin.x * imgW,
            y: (1.0 - bb.origin.y - bb.size.height) * imgH,
            width: bb.size.width * imgW,
            height: bb.size.height * imgH
        )
        let det = Detection(
            bbox: pixelRect,
            confidence: Double(largest.confidence),
            frameWidth: cgImage.width,
            frameHeight: cgImage.height
        )

        // Gate on bbox size.
        let bboxNorm = max(pixelRect.width / imgW, pixelRect.height / imgH)
        guard bboxNorm >= config.minBboxNorm else { return }

        detectionsContinuation.yield(det)

        // Convert centroid → camera-frame angle → world-frame target.
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
        let worldYaw = commandedYaw + yawOffset
        let worldPitch = commandedPitch + pitchOffset

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
            let dt = max(0.0, Double((now - lastTick).components.attoseconds) / 1.0e18)
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
            dampYawX += dt * dampYawV
            let aP = -2.0 * w * dampPitchV - (w * w) * (dampPitchX - targetPitch)
            dampPitchV += dt * aP
            dampPitchX += dt * dampPitchV

            let yawClamped = SafetyLimits.clamp(dampYawX, to: SafetyLimits.headYawMax)
            let pitchClamped = SafetyLimits.clamp(dampPitchX, to: SafetyLimits.headPitchMax)

            targetsContinuation.yield((yawClamped, pitchClamped, decay))

            // Push to streamer if attached.
            if let streamer {
                let pose = RPYPose(roll: 0, pitch: pitchClamped, yaw: yawClamped)
                await streamer.update(.init(headPose: pose), source: .face)
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
