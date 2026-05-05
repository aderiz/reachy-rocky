import Foundation
import RockyKit
import RobotLink
import Telemetry

/// Glue that turns face-tracker `Target` events into `MotionTarget` updates
/// on a `TargetStreamer`. Encapsulates the conversion (yaw/pitch radians ->
/// HeadPose matrix) and the suppression rule (don't push targets while a
/// primary recorded move is running).
///
/// Usage:
///   let bridge = FaceTargetBridge(streamer: streamer, logBus: bus)
///   await bridge.attach(to: faceTrackerService.targets)
public actor FaceTargetBridge {
    private let streamer: TargetStreamer
    private let logBus: LogBus
    private var consumer: Task<Void, Never>?
    private var suppressed: Bool = false

    public init(streamer: TargetStreamer, logBus: LogBus) {
        self.streamer = streamer
        self.logBus = logBus
    }

    public func setSuppressed(_ value: Bool) {
        suppressed = value
    }

    public func attach(to stream: AsyncStream<FaceTrackerService.Target>) {
        consumer?.cancel()
        consumer = Task { [weak self] in
            for await target in stream {
                guard let self else { return }
                await self.forward(target)
                if Task.isCancelled { break }
            }
        }
    }

    public func detach() {
        consumer?.cancel()
        consumer = nil
    }

    private func forward(_ target: FaceTrackerService.Target) async {
        guard !suppressed else { return }
        let yaw = SafetyLimits.clamp(target.yawRad, to: SafetyLimits.headYawMax)
        let pitch = SafetyLimits.clamp(target.pitchRad, to: SafetyLimits.headPitchMax)
        let pose = RPYPose(roll: 0, pitch: pitch, yaw: yaw)
        await streamer.update(.init(headPose: pose), source: .face)
    }
}
