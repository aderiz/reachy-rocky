import Foundation
import Observation
import Cognition
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
    let settings: SettingsStore
    let logBus: LogBus
    let robotEndpoint: RobotEndpoint
    let robotLink: RobotLinkClient
    let supervisor: SidecarSupervisor
    let faceTracker: FaceTrackerService
    let stateSubscriber: StateSubscriber

    // Voice
    let audioBuffer: AudioRingBuffer
    let mic: MicService
    let robotMic: RobotMicService
    let wakeFilter: WakeFilter
    let voice: VoiceCoordinator
    let appleSTT: AppleSpeechSTT
    let mediaClient: MediaClient
    let robotTTS: RobotTTS

    // Cognition
    let llm: LMStudioClient
    let toolRegistry: ToolRegistry
    let cognition: CognitionEngine

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
    var sttBackendName: String = "Apple Speech"

    // Brain state
    enum LLMStatus: Sendable, Equatable {
        case unknown
        case online(model: String)
        case offline(reason: String)
    }

    /// Models available on the active LM Studio endpoint, refreshed on every probe.
    var availableLLMModels: [String] = []
    struct BrainTurn: Sendable, Identifiable, Equatable {
        let id = UUID()
        var role: String           // "user" | "assistant" | "tool"
        var content: String
        var detail: String?        // for tool calls: args/result
        var firstChunkMs: Double?
        var totalMs: Double?
    }
    var llmStatus: LLMStatus = .unknown
    var brainTurns: [BrainTurn] = []
    var brainBusy: Bool = false
    var brainErrorMessage: String?

    /// Set whenever a TTS utterance starts; cleared when its expected
    /// duration has elapsed. Drives the "speaking" state in the UI.
    var ttsBusyUntil: Date?

    /// Manual UI mutes (separate from sidecar/permission errors).
    var ttsMuted: Bool = false

    /// Sidecar lifecycle mirrors so the Status panel can render real states
    /// without poking actors on every redraw.
    var faceTrackerSidecarState: SidecarState = .stopped
    var ttsSidecarState: SidecarState = .stopped

    enum Reachability: Sendable, Equatable {
        case unknown, online, offline(reason: String)
    }

    /// Coarse, glanceable state Rocky communicates from the menu bar and
    /// hero card. Computed from sub-states so the UI is honest.
    enum RockyState: Sendable, Equatable {
        case sleeping        // motors disabled / gravity-comp; head slumped
        case waking          // wake_up move in flight
        case idle
        case listening
        case thinking
        case speaking
        case error(String)

        var isAwake: Bool {
            switch self {
            case .sleeping, .waking, .error: false
            default: true
            }
        }
    }

    /// True while a wake_up / goto_sleep recorded move is in flight on the
    /// daemon. Set by `wakeRobot` / `sleepRobot` and cleared a few seconds
    /// later (the daemon doesn't send a "move-finished" signal we can
    /// reliably poll, so we use a duration heuristic).
    var transitioningUntil: Date?

    /// True if Rocky is currently asleep (motors disabled / gravity-comp).
    /// Read from the live state stream.
    var isAsleep: Bool {
        guard let mode = lastRobotState?.controlMode else { return false }
        return mode == .disabled || mode == .gravityCompensation
    }

    var rockyState: RockyState {
        // Errors take precedence so the user notices them.
        if case .offline(let reason) = daemonReachability {
            return .error("robot offline · \(reason)")
        }
        if let voiceError = voiceErrorMessage, !voiceError.isEmpty {
            return .error(voiceError)
        }
        if let until = transitioningUntil, Date() < until {
            return .waking
        }
        if isAsleep {
            return .sleeping
        }
        if let until = ttsBusyUntil, Date() < until {
            return .speaking
        }
        if brainBusy {
            return .thinking
        }
        if let until = conversationOpenUntil, Date() > until.addingTimeInterval(-60) {
            if Date() < until { return .listening }
        }
        if micEnabled {
            return .listening
        }
        return .idle
    }

    init() {
        let settings = SettingsStore()
        self.settings = settings
        let endpoint = settings.robotEndpoint()
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

        // Voice pipeline. Mac mic + robot mic both write into a SHARED
        // AudioRingBuffer; VoiceCoordinator pulls from it without caring
        // which source produced the bytes.
        let buf = AudioRingBuffer(capacity: 6 * 16_000)
        self.audioBuffer = buf
        self.mic = MicService(buffer: buf, logBus: bus)
        self.wakeFilter = WakeFilter()
        self.appleSTT = AppleSpeechSTT()

        // Robot-mic sidecar. Runs the reachy-mini SDK in webrtc mode.
        let robotMicManifest = Self.devRobotMicManifest()
        let robotMicDir = Self.locateSidecarDir(named: "robot-mic")
            ?? URL(fileURLWithPath: "/")
        let robotMicResolver = ManifestPathResolver(
            sidecarDir: robotMicDir,
            venvDir: SidecarSupervisor.defaultVenvDir(for: "robot-mic")
        )
        let robotMicRuntime = SidecarRuntime(
            manifest: robotMicManifest, resolver: robotMicResolver, logBus: bus
        )
        self.robotMic = RobotMicService(
            buffer: buf, sidecar: robotMicRuntime, logBus: bus
        )

        let micSource = SharedBufferAudioSource(buffer: buf)
        self.voice = VoiceCoordinator(
            source: micSource, stt: self.appleSTT, wake: self.wakeFilter, logBus: bus
        )

        // Voice out (TTS): mlx-tts sidecar. `say` backend uses /usr/bin/python3
        // and zero deps; `chatterbox` requires the [mlx] venv built via
        // `FT_EXTRAS=mlx ./Sidecars/mlx-tts/setup.sh` and runs Chatterbox
        // Turbo FP16 with the user's voice reference.
        self.mediaClient = MediaClient(endpoint: endpoint, logBus: bus)
        let ttsManifest = Self.devTTSManifest(backend: settings.ttsBackend)
        let ttsDir = Self.locateSidecarDir(named: "mlx-tts")
            ?? URL(fileURLWithPath: "/")
        let ttsResolver = ManifestPathResolver(
            sidecarDir: ttsDir,
            venvDir: SidecarSupervisor.defaultVenvDir(for: "mlx-tts")
        )
        let ttsRuntime = SidecarRuntime(
            manifest: ttsManifest, resolver: ttsResolver, logBus: bus
        )
        self.robotTTS = RobotTTS(sidecar: ttsRuntime, media: self.mediaClient, logBus: bus)

        // Cognition: LM Studio client + tool registry.
        self.llm = LMStudioClient(config: settings.lmStudioConfig(), logBus: bus)
        self.toolRegistry = ToolRegistry(logBus: bus)
        self.cognition = CognitionEngine(
            llm: self.llm,
            registry: self.toolRegistry,
            logBus: bus,
            config: .init(systemPrompt: settings.persona)
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

        // Best-effort: bring up the TTS sidecar in the background so the
        // first `say` tool call is fast. Failure is non-fatal; the LLM
        // simply hears an error on `say` until the sidecar comes up.
        Task { [robotTTS, logBus] in
            do {
                try await robotTTS.start()
            } catch {
                await logBus.publish(.error(
                    scope: "app/mlx-tts", message: "\(error)", recoverable: true
                ))
            }
        }

        // Mirror sidecar state into Observable so the Status panel can read it.
        let ftEvents = faceTracker.sidecar.events
        Task { [weak self] in
            for await event in ftEvents {
                if case .state(let s) = event {
                    await MainActor.run { self?.faceTrackerSidecarState = s }
                }
            }
        }
        let ttsEvents = robotTTS.sidecar.events
        Task { [weak self] in
            for await event in ttsEvents {
                if case .state(let s) = event {
                    await MainActor.run { self?.ttsSidecarState = s }
                }
            }
        }

        // Pump face-tracker events into observable mirrors.
        // Face-tracker target events arrive at 50 Hz. Mirroring every one
        // into Observable state thrashes SwiftUI redraws (TextField focus
        // loss, jittery layout). Coalesce to 10 Hz max for the UI; the
        // 50 Hz robot command stream still happens via TargetStreamer.
        let targets = faceTracker.targets
        let detections = faceTracker.detections
        Task { [weak self] in
            var lastUpdate = Date.distantPast
            var counter: Int = 0
            for await t in targets {
                guard let self else { return }
                counter += 1
                let now = Date()
                if now.timeIntervalSince(lastUpdate) < 0.1 { continue }
                lastUpdate = now
                let snapshot = counter
                await MainActor.run {
                    self.lastFaceTarget = t
                    self.faceTargetCount = snapshot
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
                // Try to auto-wake if Rocky is slumped on first connect.
                await self.maybeAutoWake()
            }
        }

        // Tool registry + LM Studio probe. Auto-retries every 8 s while
        // status is offline so users don't have to click "Probe" after
        // launching LM Studio.
        await registerInitialTools()
        Task { [weak self] in await self?.probeLMStudio() }
        Task { [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                let isOffline: Bool = await MainActor.run {
                    if case .offline = self.llmStatus { return true } else { return false }
                }
                if isOffline { await self.probeLMStudio() }
            }
        }

        // Speech recognition authorization.
        Task { [weak self] in await self?.warmUpSTT() }
    }

    private func warmUpSTT() async {
        let resolved = await appleSTT.requestAuthorization()
        switch resolved {
        case .ready:
            await MainActor.run { self.sttBackendName = "Apple Speech" }
        case .unavailable:
            await MainActor.run {
                self.voiceErrorMessage = "Speech recognition unavailable for the current locale."
                self.sttBackendName = "unavailable"
            }
        case .unauthorized(let status):
            await MainActor.run {
                self.voiceErrorMessage = "Speech recognition not authorized (\(status.rawValue))."
                self.sttBackendName = "unauthorized"
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
            // Stop whichever source is running.
            mic.stop()
            await robotMic.stop()
            await voice.stop()
            micEnabled = false
        } else {
            do {
                let useRobot = settings.micSource == "robot"
                if useRobot {
                    try await robotMic.start()
                    sttBackendName = "Apple Speech ← robot mic"
                } else {
                    try mic.start()
                    sttBackendName = "Apple Speech ← Mac mic"
                }
                await voice.start()
                micEnabled = true
                voiceErrorMessage = nil
                // Periodic poll so the VU meter updates without
                // bouncing through the audio thread on every frame.
                Task { [weak self] in
                    while let self, await MainActor.run(body: { self.micEnabled }) {
                        let rms: Float = useRobot
                            ? await self.robotMic.lastRMS
                            : self.mic.lastRMS
                        await MainActor.run {
                            self.lastMicRMS = rms
                        }
                        // 10 Hz: smooth-enough VU without thrashing redraws.
                        try? await Task.sleep(nanoseconds: 100_000_000)
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
            if dispatched {
                await sendUserText(text)
            }
        case .windowOpened(let until):
            await MainActor.run { self.conversationOpenUntil = until }
        case .windowClosed:
            await MainActor.run { self.conversationOpenUntil = nil }
        }
    }

    // MARK: - Brain

    func sendUserText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Probe LM Studio if we don't yet know it's online.
        if case .unknown = llmStatus { await probeLMStudio() }
        if case .offline(let reason) = llmStatus {
            await MainActor.run {
                self.brainTurns.append(.init(role: "user", content: trimmed))
                self.brainTurns.append(.init(
                    role: "assistant",
                    content: "(brain offline · \(reason)) — start LM Studio to talk to Rocky."
                ))
            }
            return
        }

        await MainActor.run {
            self.brainTurns.append(.init(role: "user", content: trimmed))
            self.brainBusy = true
        }
        let started = Date()
        var assistantBuffer = ""
        var firstChunkMs: Double?
        var assistantTurnId: UUID?

        let stream = await cognition.send(userText: trimmed)
        do {
            for try await output in stream {
                switch output {
                case .assistantDelta(let delta):
                    if firstChunkMs == nil {
                        firstChunkMs = Date().timeIntervalSince(started) * 1000
                    }
                    assistantBuffer += delta
                    let snapshot = assistantBuffer
                    let f = firstChunkMs
                    await MainActor.run {
                        if let id = assistantTurnId,
                           let idx = self.brainTurns.firstIndex(where: { $0.id == id }) {
                            self.brainTurns[idx].content = snapshot
                        } else {
                            var turn = BrainTurn(role: "assistant", content: snapshot)
                            turn.firstChunkMs = f
                            self.brainTurns.append(turn)
                            assistantTurnId = turn.id
                        }
                    }
                case .assistantFinal(_, let totalMs, let firstMs):
                    let id = assistantTurnId
                    let buf = assistantBuffer
                    await MainActor.run {
                        if let id, let idx = self.brainTurns.firstIndex(where: { $0.id == id }) {
                            self.brainTurns[idx].content = buf
                            self.brainTurns[idx].totalMs = totalMs
                            self.brainTurns[idx].firstChunkMs = firstMs
                        } else if !buf.isEmpty {
                            var t = BrainTurn(role: "assistant", content: buf)
                            t.totalMs = totalMs
                            t.firstChunkMs = firstMs
                            self.brainTurns.append(t)
                        }
                    }
                case .toolCallDispatched(let name, let argumentsJSON, _):
                    let detail = argumentsJSON
                    await MainActor.run {
                        self.brainTurns.append(.init(
                            role: "tool", content: "→ \(name)", detail: detail
                        ))
                    }
                case .toolCallResult(let result):
                    let summary = result.ok ? "ok" : "error"
                    let detail = result.resultJSON
                    let name = result.name
                    let ms = result.latencyMs
                    await MainActor.run {
                        self.brainTurns.append(.init(
                            role: "tool",
                            content: "← \(name) (\(summary), \(Int(ms))ms)",
                            detail: detail
                        ))
                    }
                case .error(let msg):
                    await MainActor.run {
                        self.brainErrorMessage = msg
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.brainErrorMessage = "\(error)"
                self.llmStatus = .offline(reason: "\(error)")
            }
        }
        await MainActor.run { self.brainBusy = false }
    }

    func resetBrain() async {
        await cognition.resetConversation()
        await MainActor.run {
            self.brainTurns.removeAll()
            self.brainErrorMessage = nil
        }
    }

    /// Toggle TTS playback. When muted, `say` tool calls return immediately
    /// without going through the sidecar.
    func toggleTTSMute() async {
        ttsMuted.toggle()
        if ttsMuted {
            try? await robotTTS.cancel()
            ttsBusyUntil = nil
        }
    }

    /// Stop face tracking from pushing target events into the streamer.
    func setFaceTrackingEnabled(_ enabled: Bool) async {
        do {
            try await faceTracker.setEnabled(enabled)
        } catch {
            await logBus.publish(.error(
                scope: "app/face-tracker",
                message: "setEnabled: \(error)",
                recoverable: true
            ))
        }
    }

    /// Has the auto-wake-on-connect logic already fired this session?
    private var hasAutoWokenThisSession = false

    func wakeRobot() async {
        // The wake_up recorded move runs ~2-3s; give the avatar a small
        // settle margin afterwards.
        await MainActor.run {
            self.transitioningUntil = Date().addingTimeInterval(3.5)
        }
        do { try await robotLink.wakeUp() }
        catch {
            await MainActor.run { self.transitioningUntil = nil }
            await logBus.publish(.error(
                scope: "app/wake", message: "\(error)", recoverable: true
            ))
        }
    }

    func sleepRobot() async {
        // goto_sleep runs ~2.7s and is followed by motor-disable. The
        // RobotLinkClient already awaits the full sequence; we keep the
        // transition flag a bit longer so the slump animation is visible.
        await MainActor.run {
            self.transitioningUntil = Date().addingTimeInterval(4.0)
        }
        do { try await robotLink.goToSleep() }
        catch {
            await MainActor.run { self.transitioningUntil = nil }
            await logBus.publish(.error(
                scope: "app/sleep", message: "\(error)", recoverable: true
            ))
        }
    }

    /// Auto-wake Rocky if (a) we just confirmed the daemon is online, (b) the
    /// reported motor mode is disabled / gravity-comp, and (c) we haven't
    /// already triggered an auto-wake this session. Called from the state
    /// stream loop; no-ops most of the time.
    fileprivate func maybeAutoWake() async {
        guard !hasAutoWokenThisSession else { return }
        guard case .online = daemonReachability else { return }
        guard isAsleep else {
            // Already awake on connect — count it as "auto-handled" so we
            // don't unnecessarily wake on a subsequent state blip.
            hasAutoWokenThisSession = true
            return
        }
        hasAutoWokenThisSession = true
        await logBus.publish(.sidecarLog(
            sidecar: "app", level: .info,
            message: "auto-waking robot on connect", fields: [:]
        ))
        await wakeRobot()
    }

    private func probeLMStudio() async {
        do {
            let models = try await llm.listModels()
            let pinned = settings.lmStudioModel
            // If the pinned model exists in the list, report it as the
            // active one. Otherwise fall back to the first available.
            let active: String
            if !pinned.isEmpty, models.contains(pinned) {
                active = pinned
            } else {
                active = models.first ?? "(no models loaded)"
            }
            await MainActor.run {
                self.llmStatus = .online(model: active)
                self.availableLLMModels = models
            }
        } catch {
            await MainActor.run {
                self.llmStatus = .offline(reason: "\(error)")
                self.availableLLMModels = []
            }
        }
    }

    /// Public entry points so the Status panel can re-run probes.
    func probeRobotPublic() async { await probeRobot() }
    func probeLMStudioPublic() async { await probeLMStudio() }

    /// Apply the latest values from the SettingsStore. The endpoint can't be
    /// changed at runtime without a relaunch (URLSession sockets, sidecars,
    /// etc. all hold the original); we update what's safe (LM Studio + persona).
    func applySettings() async {
        await llm.setConfig(settings.lmStudioConfig())
        await cognition.setConfig(.init(systemPrompt: settings.persona))
        await probeLMStudio()
    }

    // MARK: - Tools

    private func registerInitialTools() async {
        let robot = robotLink
        let bus = logBus

        await toolRegistry.register(
            name: "look_at",
            description: "Make Rocky orient his head toward a yaw/pitch in degrees. Yaw: -180..180 (positive = left). Pitch: -40..40 (positive = down). Smooth.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "yaw_deg":    .object(["type": .string("number")]),
                    "pitch_deg":  .object(["type": .string("number")]),
                    "duration_s": .object(["type": .string("number")]),
                ]),
                "required": .array([.string("yaw_deg")]),
            ]),
            handler: { args in
                let yaw = (args.asObject?["yaw_deg"]?.asNumber ?? 0) * .pi / 180
                let pitch = (args.asObject?["pitch_deg"]?.asNumber ?? 0) * .pi / 180
                let duration = args.asObject?["duration_s"]?.asNumber ?? 0.6
                let pose = RPYPose(roll: 0, pitch: pitch, yaw: yaw)
                try await robot.goto(headPose: pose, durationS: duration)
                await bus.publish(.motorCommand(
                    source: .tool,
                    target: MotionTarget(headPose: pose)
                ))
                return .object([
                    "ok": .bool(true),
                    "yaw_rad": .number(yaw),
                    "pitch_rad": .number(pitch),
                ])
            }
        )

        await toolRegistry.register(
            name: "set_motor_mode",
            description: "Set the robot's motor mode. Choices: enabled, disabled, gravity_compensation.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "mode": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("mode")]),
            ]),
            handler: { args in
                guard let raw = args.asObject?["mode"]?.asString,
                      let mode = MotorMode(rawValue: raw) else {
                    return .object(["ok": .bool(false), "error": .string("invalid mode")])
                }
                try await robot.setMotorMode(mode)
                return .object(["ok": .bool(true), "mode": .string(mode.rawValue)])
            }
        )

        await toolRegistry.register(
            name: "wake_up",
            description: "Wake Rocky up (enable motors and play the wake-up move).",
            handler: { _ in
                try await robot.wakeUp()
                return .object(["ok": .bool(true)])
            }
        )

        await toolRegistry.register(
            name: "go_to_sleep",
            description: "Send Rocky to sleep (disable motors after a goodbye gesture).",
            handler: { _ in
                try await robot.goToSleep()
                return .object(["ok": .bool(true)])
            }
        )

        await toolRegistry.register(
            name: "stop_motion",
            description: "Stop any in-flight recorded move immediately.",
            handler: { _ in
                try await robot.stopMove()
                return .object(["ok": .bool(true)])
            }
        )

        // Curated subset of the Pollen emotions library; full list pulled
        // live by Status if needed. Keeping the schema enum here keeps the
        // LLM honest about what's actually available.
        let emotions: [String] = [
            "amazed1", "anxiety1", "attentive1", "boredom1", "calming1",
            "cheerful1", "come1", "confused1", "contempt1", "curious1",
            "dance1", "dance2", "dance3",
            "disgusted1", "displeased1", "downcast1",
            "enthusiastic1", "exhausted1", "fear1", "frustrated1", "furious1",
            "go_away1", "grateful1", "helpful1", "impatient1",
            "indifferent1", "inquiring1", "irritated1",
            "laughing1", "lonely1", "lost1", "loving1",
            "no1", "no_excited1", "no_sad1", "oops1",
            "proud1", "rage1", "relief1", "reprimand1",
            "resigned1", "sad1", "scared1", "serenity1", "shy1",
            "sleep1", "success1", "surprised1", "thoughtful1",
            "tired1", "uncertain1", "uncomfortable1",
            "understanding1", "welcoming1", "yes1", "yes_sad1",
        ]

        await toolRegistry.register(
            name: "play_emotion",
            description: """
            Play a recorded emotion from the Pollen Robotics library on the robot's body.
            Use sparingly — these are full-body gestures (~1-3s) that take over the head and antennas.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "enum": .array(emotions.map { .string($0) }),
                        "description": .string("Emotion to play"),
                    ]),
                ]),
                "required": .array([.string("name")]),
            ]),
            handler: { args in
                guard let name = args.asObject?["name"]?.asString,
                      emotions.contains(name) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("unknown emotion"),
                    ])
                }
                try await robot.playRecordedMove(
                    dataset: "pollen-robotics/reachy-mini-emotions-library",
                    move: name
                )
                return .object(["ok": .bool(true), "emotion": .string(name)])
            }
        )

        let visionService = faceTracker
        await toolRegistry.register(
            name: "pause_face_tracking",
            description: "Stop the face-tracker sidecar from steering the head. Use before a recorded emotion.",
            handler: { _ in
                try await visionService.setEnabled(false)
                return .object(["ok": .bool(true)])
            }
        )
        await toolRegistry.register(
            name: "resume_face_tracking",
            description: "Resume the face-tracker sidecar.",
            handler: { _ in
                try await visionService.setEnabled(true)
                return .object(["ok": .bool(true)])
            }
        )

        let tts = robotTTS
        await toolRegistry.register(
            name: "say",
            description: "Speak the given text aloud through Rocky's speaker.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("text")]),
            ]),
            handler: { [weak self] args in
                let text = args.asObject?["text"]?.asString ?? ""
                guard !text.isEmpty else {
                    return .object(["ok": .bool(false),
                                    "error": .string("empty text")])
                }
                if await MainActor.run(body: { self?.ttsMuted ?? false }) {
                    return .object(["ok": .bool(false), "error": .string("tts muted")])
                }
                let stats = try await tts.speak(text)
                // Drive the "speaking" hero state: report busy through the
                // duration of the synthesized clip + a small tail.
                if let self {
                    let until = Date().addingTimeInterval(stats.durationS + 0.2)
                    await MainActor.run { self.ttsBusyUntil = until }
                }
                return .object([
                    "ok": .bool(true),
                    "synth_ms": .number(stats.synthMs),
                    "upload_ms": .number(stats.uploadMs),
                    "duration_s": .number(stats.durationS),
                ])
            }
        )

        await toolRegistry.register(
            name: "stop_speaking",
            description: "Stop any in-progress robot speech.",
            handler: { _ in
                try await tts.cancel()
                return .object(["ok": .bool(true)])
            }
        )

        await toolRegistry.register(
            name: "get_state",
            description: "Return Rocky's current head pose, antennas, and body yaw.",
            handler: { [weak self] _ in
                guard let self else { return .null }
                let state = try await self.robotLink.fullState()
                return .object([
                    "control_mode": .string(state.controlMode.rawValue),
                    "head_yaw_deg":   .number(state.headPose.yaw   * 180 / .pi),
                    "head_pitch_deg": .number(state.headPose.pitch * 180 / .pi),
                    "head_roll_deg":  .number(state.headPose.roll  * 180 / .pi),
                    "body_yaw_deg":   .number(state.bodyYaw        * 180 / .pi),
                    "antenna_right_rad": .number(state.antennasPosition.right),
                    "antenna_left_rad":  .number(state.antennasPosition.left),
                ])
            }
        )
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

    private nonisolated static func devTTSManifest(backend: String) -> SidecarManifest {
        let venvPython = SidecarSupervisor.defaultVenvDir(for: "mlx-tts")
            .appendingPathComponent("bin/python")
        let isChatterbox = backend == "chatterbox"
        let useVenv = isChatterbox && FileManager.default.fileExists(atPath: venvPython.path)
        let binary = useVenv ? venvPython.path : "/usr/bin/python3"
        let resolvedBackend = useVenv ? "chatterbox" : "say"
        let sidecarDir = locateSidecarDir(named: "mlx-tts")?
            .path(percentEncoded: false) ?? "."
        var env: [String: String] = [
            "PYTHONPATH": sidecarDir,
            "ROCKY_TTS_BACKEND": resolvedBackend,
        ]
        if resolvedBackend == "say" {
            env["ROCKY_TTS_VOICE"] = "Samantha"
            env["ROCKY_TTS_RATE"] = "180"
        }
        return SidecarManifest(
            name: "mlx-tts",
            version: "0.1.0-dev",
            binary: binary,
            args: ["-u", "-m", "rocky_tts.runner"],
            workingDir: sidecarDir,
            env: env,
            readyTimeoutS: 30,
            shutdownGraceS: 3,
            // Chatterbox first synth includes a model load; bump the timeout.
            timeouts: ["*": 5, "synthesize": isChatterbox ? 60 : 30]
        )
    }

    /// Reads from a shared AudioRingBuffer no matter which producer wrote
    /// (Mac mic or robot mic).
    private struct SharedBufferAudioSource: VoiceCoordinator.AudioFrameSource {
        let buffer: AudioRingBuffer

        func nextFrame(maxSamples: Int) async -> [Float] {
            var out: [Float] = []
            _ = buffer.read(into: &out, max: maxSamples)
            return out
        }
    }

    private nonisolated static func devRobotMicManifest() -> SidecarManifest {
        let venvPython = SidecarSupervisor.defaultVenvDir(for: "robot-mic")
            .appendingPathComponent("bin/python")
        let dir = locateSidecarDir(named: "robot-mic")?
            .path(percentEncoded: false) ?? "."
        return SidecarManifest(
            name: "robot-mic",
            version: "0.1.0-dev",
            binary: venvPython.path,
            args: ["-u", "-m", "rocky_robot_mic.runner"],
            workingDir: dir,
            env: [
                "PYTHONPATH": dir,
                "ROCKY_ROBOT_HOST": "reachy-mini.local",
                "ROCKY_ROBOT_PORT": "8000",
            ],
            readyTimeoutS: 30,
            shutdownGraceS: 3,
            timeouts: ["*": 10]
        )
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
