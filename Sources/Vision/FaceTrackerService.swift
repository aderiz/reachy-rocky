import Foundation
import CoreGraphics
import RockyKit
import RobotLink
import SidecarHost
import Telemetry

/// Typed adapter over the `face-tracker` Python sidecar.
///
/// Consumes raw `event` envelopes (`target`, `detection`, `preview`) and
/// surfaces them as Swift streams. Forwards target updates into a
/// `TargetStreamer` (when one is wired in by `Rocky`'s `AppServices`).
public actor FaceTrackerService {
    public struct Detection: Sendable, Equatable {
        public let bbox: CGRect
        public let confidence: Double
        public let promptId: String
        public let frameWidth: Int
        public let frameHeight: Int

        public init(bbox: CGRect, confidence: Double, promptId: String,
                    frameWidth: Int, frameHeight: Int) {
            self.bbox = bbox
            self.confidence = confidence
            self.promptId = promptId
            self.frameWidth = frameWidth
            self.frameHeight = frameHeight
        }
    }

    public struct Target: Sendable, Equatable {
        public let yawRad: Double
        public let pitchRad: Double
        public let decayActive: Bool

        public init(yawRad: Double, pitchRad: Double, decayActive: Bool) {
            self.yawRad = yawRad
            self.pitchRad = pitchRad
            self.decayActive = decayActive
        }
    }

    // MARK: - Public

    public nonisolated let sidecar: any Sidecar
    public nonisolated let detections: AsyncStream<Detection>
    public nonisolated let targets: AsyncStream<Target>

    private let detectionsContinuation: AsyncStream<Detection>.Continuation
    private let targetsContinuation: AsyncStream<Target>.Continuation
    private let logBus: LogBus
    private var pumpTask: Task<Void, Never>?

    public init(sidecar: any Sidecar, logBus: LogBus) {
        self.sidecar = sidecar
        self.logBus = logBus

        var dc: AsyncStream<Detection>.Continuation!
        self.detections = AsyncStream<Detection>(
            bufferingPolicy: .bufferingNewest(64)
        ) { c in dc = c }
        self.detectionsContinuation = dc

        var tc: AsyncStream<Target>.Continuation!
        self.targets = AsyncStream<Target>(
            bufferingPolicy: .bufferingNewest(256)
        ) { c in tc = c }
        self.targetsContinuation = tc
    }

    // MARK: - Lifecycle

    public func start() async throws {
        try await sidecar.start()
        pumpTask?.cancel()
        let stream = sidecar.events
        pumpTask = Task { [weak self] in
            await self?.pump(stream: stream)
        }
    }

    public func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        await sidecar.stop()
        detectionsContinuation.finish()
        targetsContinuation.finish()
    }

    // MARK: - Control methods (forwarded to the sidecar)

    public func setEnabled(_ enabled: Bool) async throws {
        struct P: Encodable, Sendable { let enabled: Bool }
        struct R: Decodable, Sendable { let enabled: Bool }
        let _: R = try await sidecar.send(method: "set_enabled", params: P(enabled: enabled))
    }

    public func setPrompt(_ text: String) async throws {
        struct P: Encodable, Sendable { let text: String }
        struct R: Decodable, Sendable { let prompt: String }
        let _: R = try await sidecar.send(method: "set_prompt", params: P(text: text))
    }

    public func updateCommandedPose(yawRad: Double, pitchRad: Double) async throws {
        struct P: Encodable, Sendable { let yaw_rad: Double; let pitch_rad: Double }
        struct R: Decodable, Sendable { let ok: Bool }
        let _: R = try await sidecar.send(
            method: "update_commanded_pose",
            params: P(yaw_rad: yawRad, pitch_rad: pitchRad)
        )
    }

    // MARK: - Internal pump

    private func pump(stream: AsyncStream<SidecarOutboundEvent>) async {
        for await event in stream {
            switch event {
            case .event(let name, let payload):
                handleEvent(name: name, payload: payload)
            case .state, .log:
                continue
            }
            if Task.isCancelled { break }
        }
    }

    private func handleEvent(name: String, payload: Data) {
        switch name {
        case "target":
            guard
                let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                let yaw = dict["yaw_rad"] as? Double,
                let pitch = dict["pitch_rad"] as? Double
            else { return }
            let decay = (dict["decay_active"] as? Bool) ?? false
            let t = Target(yawRad: yaw, pitchRad: pitch, decayActive: decay)
            targetsContinuation.yield(t)
            Task { await logBus.publish(.faceTarget(yawRad: yaw, pitchRad: pitch, decayActive: decay)) }
        case "detection":
            guard
                let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                let bbox = dict["bbox"] as? [Double], bbox.count == 4,
                let conf = dict["confidence"] as? Double,
                let frameW = dict["frame_w"] as? Int,
                let frameH = dict["frame_h"] as? Int,
                let promptId = dict["prompt_id"] as? String
            else { return }
            let rect = CGRect(x: bbox[0], y: bbox[1], width: bbox[2], height: bbox[3])
            let d = Detection(
                bbox: rect, confidence: conf, promptId: promptId,
                frameWidth: frameW, frameHeight: frameH
            )
            detectionsContinuation.yield(d)
            Task { await logBus.publish(.faceDetection(bbox: rect, confidence: conf, promptId: promptId)) }
        default:
            break
        }
    }
}
