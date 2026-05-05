import Foundation
import Observation
import RobotLink
import RockyKit
import SidecarHost
import Telemetry
import Vision
import Voice

/// One owner for every long-lived service Rocky uses. Injected via `.environment(...)`.
@Observable
@MainActor
final class AppServices {
    let logBus: LogBus
    let robotEndpoint: RobotEndpoint
    let robotLink: RobotLinkClient
    let supervisor: SidecarSupervisor
    let faceTracker: FaceTrackerService
    let stateSubscriber: StateSubscriber

    // Voice
    let mic: MicService
    let wakeFilter: WakeFilter
    let voice: VoiceCoordinator
    let echoSTT: EchoSTT          // placeholder until WhisperKit lands

    /// Most recent reachability check for the daemon.
    var daemonReachability: Reachability = .unknown
    var lastDaemonStatus: RobotLinkClient.DaemonStatus?
    var lastRobotState: RobotState?
    var stateUpdateCount: Int = 0

    /// Live mirror of the latest face-tracker target so the Vision card can render it.
    var lastFaceTarget: FaceTrackerService.Target?
    var lastFaceDetection: FaceTrackerService.Detection?
    var faceTargetCount: Int = 0
    var faceDetectionCount: Int = 0

    // Live voice state
    var micEnabled: Bool = false
    var lastMicRMS: Float = 0
    var lastTranscript: String = ""
    var lastDispatched: String?
    var conversationOpenUntil: Date?
    var voiceErrorMessage: String?

    enum Reachability: Sendable, Equatable {
        case unknown, online, offline(reason: String)
    }

    init(endpoint: RobotEndpoint = RobotEndpoint()) {
        let bus = LogBus()
        self.logBus = bus
        self.robotEndpoint = endpoint
        self.robotLink = RobotLinkClient(endpoint: endpoint, logBus: bus)
        self.supervisor = SidecarSupervisor(logBus: bus)
        self.stateSubscriber = StateSubscriber(endpoint: endpoint, logBus: bus)

        // Build the face-tracker sidecar in dev mode (synthetic detector,
        // /usr/bin/python3, no venv). Real-robot mode swaps the manifest
        // during onboarding (M7).
        let manifest = Self.devFaceTrackerManifest()
        let dir = Self.locateSidecarDir(named: "face-tracker")
            ?? URL(fileURLWithPath: "/")
        let resolver = ManifestPathResolver(
            sidecarDir: dir,
            venvDir: SidecarSupervisor.defaultVenvDir(for: "face-tracker")
        )
        let runtime = SidecarRuntime(manifest: manifest, resolver: resolver, logBus: bus)
        self.faceTracker = FaceTrackerService(sidecar: runtime, logBus: bus)

        // Voice pipeline. EchoSTT is a placeholder; WhisperKit replaces it.
        self.mic = MicService(logBus: bus)
        self.wakeFilter = WakeFilter()
        self.echoSTT = EchoSTT()
        let micSource = MicFrameSource(mic: self.mic)
        self.voice = VoiceCoordinator(
            source: micSource, stt: self.echoSTT, wake: self.wakeFilter, logBus: bus
        )
    }

    /// Spin up long-lived services. Idempotent enough to be safe to call once
    /// from `RockyApp.task { ... }`.
    func start() async {
        do {
            try await faceTracker.start()
        } catch {
            await logBus.publish(.error(scope: "app/face-tracker",
                                        message: "\(error)",
                                        recoverable: true))
        }

        // Pump face-tracker events into observable mirrors.
        let targets = faceTracker.targets
        let detections = faceTracker.detections
        Task { [weak self] in
            for await t in targets {
                guard let self else { return }
                await MainActor.run {
                    self.lastFaceTarget = t
                    self.faceTargetCount &+= 1
                }
            }
        }
        Task { [weak self] in
            for await d in detections {
                guard let self else { return }
                await MainActor.run {
                    self.lastFaceDetection = d
                    self.faceDetectionCount &+= 1
                }
            }
        }

        // First daemon health probe. Failure is expected when the robot is off.
        Task { [weak self] in
            guard let self else { return }
            await self.probeRobot()
        }

        // Subscribe to live state. Reconnects with backoff on transport errors.
        await stateSubscriber.start()
        let states = stateSubscriber.states
        Task { [weak self] in
            for await state in states {
                guard let self else { return }
                await MainActor.run {
                    self.lastRobotState = state
                    self.stateUpdateCount &+= 1
                    if self.daemonReachability != .online {
                        self.daemonReachability = .online
                    }
                }
            }
        }
    }

    func stop() async {
        await voice.stop()
        await stateSubscriber.stop()
        await faceTracker.stop()
        mic.stop()
    }

    // MARK: - Voice control

    func toggleMic() async {
        if micEnabled {
            mic.stop()
            await voice.stop()
            micEnabled = false
        } else {
            do {
                try mic.start()
                await voice.start()
                micEnabled = true
                voiceErrorMessage = nil
                // Periodic poll so the VU meter updates without
                // bouncing through the audio thread on every frame.
                Task { [weak self] in
                    while let self, await MainActor.run(body: { self.micEnabled }) {
                        let rms = self.mic.lastRMS
                        await MainActor.run {
                            self.lastMicRMS = rms
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                // Pump voice outputs into observable mirrors.
                let outputs = voice.outputs
                Task { [weak self] in
                    for await output in outputs {
                        guard let self else { return }
                        await self.handleVoice(output)
                    }
                }
            } catch {
                voiceErrorMessage = "\(error)"
            }
        }
    }

    private func handleVoice(_ output: VoiceCoordinator.Output) async {
        switch output {
        case .partial(let text):
            await MainActor.run { self.lastTranscript = text }
        case .finalText(let text, let dispatched, _):
            await MainActor.run {
                self.lastTranscript = text
                if dispatched { self.lastDispatched = text }
            }
        case .windowOpened(let until):
            await MainActor.run { self.conversationOpenUntil = until }
        case .windowClosed:
            await MainActor.run { self.conversationOpenUntil = nil }
        }
    }

    private func probeRobot() async {
        do {
            let status = try await robotLink.daemonStatus()
            self.lastDaemonStatus = status
            self.daemonReachability = .online
        } catch RobotLinkError.transport(let msg) {
            self.daemonReachability = .offline(reason: msg)
        } catch {
            self.daemonReachability = .offline(reason: "\(error)")
        }
    }

    // MARK: - Helpers

    private nonisolated static func devFaceTrackerManifest() -> SidecarManifest {
        SidecarManifest(
            name: "face-tracker",
            version: "0.1.0-dev",
            binary: "/usr/bin/python3",
            args: ["-u", "-m", "rocky_face_tracker.runner"],
            workingDir: locateSidecarDir(named: "face-tracker")?
                .path(percentEncoded: false) ?? ".",
            env: [
                "PYTHONPATH": locateSidecarDir(named: "face-tracker")?
                    .path(percentEncoded: false) ?? ".",
                "ROCKY_FT_MODE": "synthetic",
                "ROCKY_FT_HFOV_DEG": "65",
                "ROCKY_FT_VFOV_DEG": "39",
                "ROCKY_FT_DAMPER_OMEGA": "3.0",
                "ROCKY_FT_EMA_ALPHA": "0.5",
                "ROCKY_FT_IDLE_TIMEOUT_S": "1.5",
                "ROCKY_FT_PROMPT": "a brunette male with a beard",
            ],
            readyTimeoutS: 15,
            shutdownGraceS: 3
        )
    }

    /// Adapter that turns `MicService.buffer` into a `VoiceCoordinator.AudioFrameSource`.
    private struct MicFrameSource: VoiceCoordinator.AudioFrameSource {
        let mic: MicService

        func nextFrame(maxSamples: Int) async -> [Float] {
            var out: [Float] = []
            _ = mic.buffer.read(into: &out, max: maxSamples)
            return out
        }
    }

    /// Walk up from this source file until we find `Sidecars/<name>/`. Works
    /// during `swift run` because tests and dev binaries both run from the
    /// repo's workspace.
    private nonisolated static func locateSidecarDir(
        named name: String,
        startingAt file: String = #filePath
    ) -> URL? {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        while url.path != "/" {
            let candidate = url
                .appendingPathComponent("Sidecars", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }
}
