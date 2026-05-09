import Foundation
import Observation
import Speech
import SwiftUI
import Cognition
import RobotLink
import RockyKit
import SidecarHost
import Telemetry
import RockyVision
import Voice
import Perception
import Memory

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
    let faceTargetBridge: FaceTargetBridge
    let targetStreamer: TargetStreamer
    let robotCamera: RobotCameraService
    let macFaceTracker: MacFaceTracker
    let faceLibrary: FaceLibrary
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

    /// Single source of truth for permission status across every UI
    /// surface (FirstRunOverlay, Settings → Permissions, Health
    /// rows). Tools also read through it so the user-visible label
    /// matches what the tool actually sees.
    let permissions = PermissionsAuthority()

    // Cognition
    let llm: LMStudioClient
    let toolRegistry: ToolRegistry
    let cognition: CognitionEngine
    let memory: MemoryService
    /// Coalesces telemetry events into narrative moments at human
    /// cadence. Drives the cockpit's margin strip, the menu-bar
    /// popover's "Recent" section, and the Inspector's Activity tab.
    let momentFeed: MomentFeed

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

    /// Mirror of the on-disk face library (snapshot refreshed after enroll
    /// / remove). The Settings view binds against this for the list UI.
    var enrolledPeople: [FaceLibrary.Person] = []

    /// Per-person "last seen" timestamps. Drives the greeting state
    /// machine: a name re-entering after `presenceAbsenceThreshold`
    /// seconds of absence triggers a fresh "hey, {name}".
    @ObservationIgnored
    private var personPresence: [String: Date] = [:]
    @ObservationIgnored
    private var lastGreetingIndex: Int?
    private let presenceAbsenceThreshold: TimeInterval = 30.0
    /// Rocky-voice greetings. The LLM persona explains the rules: third
    /// person "Rocky", no articles, base-form verbs, short clauses,
    /// catchphrases for delight. These are spoken directly via TTS (no
    /// LLM round-trip) so they need to be in-voice on their own.
    private static let greetingTemplates: [String] = [
        "{name}!",
        "Rocky see {name}.",
        "{name} back!",
        "{name} here. Rocky happy.",
        "Amaze amaze amaze. {name}!",
        "Hello {name}. Fist my bump.",
        "{name} friend.",
    ]

    /// Latest robot-camera frame as JPEG data (the SwiftUI side decodes it).
    var lastCameraFrame: RobotCameraService.Frame?

    /// Wall-clock timestamp of the most recent camera frame from the
    /// robot-camera sidecar. Stamped on every frame so the Health
    /// surface can distinguish "streaming live" from "sidecar
    /// respawning / WebRTC dropped". Same shape as `lastMicFrameAt`.
    var lastCameraFrameAt: Date?
    var cameraFrameCount: Int = 0

    // Live voice state
    var micEnabled: Bool = false
    var lastMicRMS: Float = 0
    /// Wall-clock timestamp of the most recent audio frame the Health
    /// surfaces should treat as "alive". Mirror of `RobotMicService.lastFrameAt`
    /// (or `MicService.lastFrameAt` for the Mac mic). When `micEnabled`
    /// is true but this is older than ~3s, the mic is silently stalled
    /// and the Health row reflects warning, not green.
    var lastMicFrameAt: Date?
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

    /// Effective TTS-mute state honoured by speak callsites: the user-
    /// controlled `ttsMuted` toggle OR the time-bounded quiet-mode
    /// (`dndUntil`). Use this in any callsite that asks "should we
    /// speak right now?" so the menu-bar's pause-for-X actually
    /// silences Rocky's voice as well as cutting off dispatch.
    var effectiveTTSMuted: Bool { ttsMuted || isDoNotDisturb }

    /// Whether the on-Mac face tracker is allowed to push targets to the
    /// streamer. Driven by `setFaceTrackingEnabled` so menu bar and any
    /// future dashboard control read the same source of truth.
    var faceTrackingEnabled: Bool = true

    /// Sidecar lifecycle mirrors so the Status panel can render real states
    /// without poking actors on every redraw.
    var faceTrackerSidecarState: SidecarState = .stopped
    var ttsSidecarState: SidecarState = .stopped
    var memorySidecarState: SidecarState = .stopped

    /// Total drawers in Rocky's palace. Polled lazily — see
    /// `refreshMemoryCount()`. `-1` means "haven't asked yet" so the
    /// UI can show a neutral placeholder rather than a misleading 0.
    var memoryDrawerCount: Int = -1

    /// Recent narrative moments — the human-cadence successor to
    /// `LogsView`. Mirror of the most recent slice of `MomentFeed`'s
    /// ring buffer, re-published on each new moment so SwiftUI views
    /// (the Activity tab, the cockpit margin strip, the menu-bar
    /// popover) re-render at moment cadence rather than firehose.
    var recentMoments: [Moment] = []

    /// Whether the ⌘K command palette sheet is currently open. Lives
    /// here (rather than in RootView's `@State`) so both the keyboard
    /// shortcut handler in the cockpit AND the Edit-menu command can
    /// toggle the same flag.
    var commandPaletteOpen: Bool = false

    /// Quiet mode. When set to a future date, Rocky stops dispatching
    /// the wake-word pipeline (mic stays warm but user utterances aren't
    /// routed to the brain) and TTS playback is held. Wired by the
    /// menu-bar popover's "pause Rocky for X" control. Cleared
    /// automatically when the date passes; UI watchers should redraw on
    /// mutation.
    var dndUntil: Date?

    /// True iff `dndUntil` is in the future. Used by the wake/STT/TTS
    /// pipelines as a single gate.
    var isDoNotDisturb: Bool {
        guard let until = dndUntil else { return false }
        if Date() >= until {
            // Lazy clear: avoid stale state if a UI consumer reads us
            // long after the timer should have expired.
            dndUntil = nil
            return false
        }
        return true
    }

    /// Mute Rocky for `minutes`. Pass nil to clear.
    func pauseFor(minutes: Int?) {
        if let m = minutes, m > 0 {
            dndUntil = Date().addingTimeInterval(TimeInterval(m * 60))
        } else {
            dndUntil = nil
        }
    }

    /// Toolbar-level health summary. Three states: ok (green-ish, quiet),
    /// warning (orange, something needs attention), critical (red, robot
    /// offline). Per the cockpit design, this is the *only* always-visible
    /// status indicator on the main window; the seven-pill detail lives
    /// in the Inspector → Health tab.
    struct HealthGlance: Sendable, Equatable {
        let label: String
        let symbol: String
        let tint: Color
        /// Human-readable description of the *worst* current issue, for
        /// the toolbar tooltip. `nil` means everything is fine.
        let tooltip: String?
    }

    var healthGlance: HealthGlance {
        // Robot reachability is the most-fatal failure: if Rocky's body
        // is unreachable, surface that first.
        if case .offline(let reason) = daemonReachability {
            return HealthGlance(
                label: "Robot offline",
                symbol: "wifi.exclamationmark",
                tint: .red,
                tooltip: "Robot offline — \(reason)"
            )
        }
        // LM Studio offline isn't fatal but is amber.
        if case .offline(let reason) = llmStatus {
            return HealthGlance(
                label: "Brain offline",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                tooltip: "LM Studio offline — \(reason)"
            )
        }
        // Sidecar lifecycle issues.
        if let bad = firstUnhealthySidecar() {
            return HealthGlance(
                label: bad,
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                tooltip: "\(bad) needs attention."
            )
        }
        // Otherwise: quiet glyph, no tooltip.
        return HealthGlance(
            label: "Healthy",
            symbol: "checkmark.circle.fill",
            tint: .green,
            tooltip: nil
        )
    }

    private func firstUnhealthySidecar() -> String? {
        for (name, state) in [
            ("Face tracker", faceTrackerSidecarState),
            ("Voice", ttsSidecarState),
            ("Memory", memorySidecarState),
        ] {
            switch state {
            case .ready, .stopped, .starting:
                continue
            case .failing, .circuitOpen:
                return "\(name) sidecar"
            }
        }
        return nil
    }

    enum Reachability: Sendable, Equatable {
        case unknown, online, offline(reason: String)
    }

    /// Top-level bot behaviour mode. The four-state model the user
    /// asked for: a single, glanceable status. `RockyState` below is
    /// kept for finer-grained avatar cues (listening / thinking /
    /// speaking inside `engaged`) but `botMode` is what the UI shows
    /// as the primary indicator.
    enum BotMode: Sendable, Equatable {
        case sleeping       // motors disabled / gravity-comp
        case idle           // awake, no person identified
        case active         // awake, tracking a person
        case engaged        // in active dialogue
        case error(String)
    }

    /// Computed top-level mode. Only escalates to `.error` for
    /// daemon-level problems — i.e. the robot itself is unreachable.
    /// Voice / mic / sidecar errors are surfaced in their own card
    /// (Voice card, Logs view) so a mic permission issue doesn't
    /// cause the dashboard to claim the robot is in error when the
    /// daemon probe says it's online.
    var botMode: BotMode {
        if case .offline(let reason) = daemonReachability {
            return .error("robot offline · \(reason)")
        }
        if isAsleep { return .sleeping }
        if let until = ttsBusyUntil, Date() < until { return .engaged }
        if brainBusy { return .engaged }
        if let until = conversationOpenUntil, Date() < until { return .engaged }
        if let last = lastFaceDetectionAt,
           Date().timeIntervalSince(last) < 8.0 {
            return .active
        }
        return .idle
    }

    /// Coarse, glanceable state Rocky communicates from the menu bar and
    /// hero card. Computed from sub-states so the UI is honest.
    enum RockyState: Sendable, Equatable {
        case sleeping        // motors disabled / gravity-comp; head slumped
        case waking          // wake_up move in flight
        case idle            // awake, no face in view, no audio activity
        case tracking        // awake + a face is currently in view
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

    /// Wall-clock timestamp of the most recent face detection. The
    /// `rockyState` computation reads this to surface a `.tracking`
    /// status whenever a face has been visible in the last few seconds.
    var lastFaceDetectionAt: Date?
    /// How recent a detection must be (seconds) to count as "currently
    /// tracking". Slightly longer than the camera frame interval so a
    /// single dropped frame doesn't flicker the state.
    private let trackingWindowS: TimeInterval = 1.5

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
        // Only the daemon being unreachable is a global "error" — voice
        // and other peripheral failures stay in their own surfaces and
        // don't cause the top-level avatar to claim error.
        if case .offline(let reason) = daemonReachability {
            return .error("robot offline · \(reason)")
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
        // Awake + a face has been in view recently → "tracking" so the
        // user gets honest feedback that Rocky is paying attention,
        // rather than `.idle` while the head is actively following.
        if let last = lastFaceDetectionAt,
           Date().timeIntervalSince(last) < trackingWindowS {
            return .tracking
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

        // Wire face-tracker targets into a 50 Hz set_target stream so the
        // robot actually moves when faces are detected.
        self.targetStreamer = TargetStreamer(client: self.robotLink, logBus: bus)
        self.faceTargetBridge = FaceTargetBridge(
            streamer: self.targetStreamer, logBus: bus
        )

        // Robot-camera sidecar. Streams JPEG frames over the wire.
        let cameraManifest = Self.devRobotCameraManifest()
        let cameraDir = Self.locateSidecarDir(named: "robot-camera")
            ?? URL(fileURLWithPath: "/")
        let cameraResolver = ManifestPathResolver(
            sidecarDir: cameraDir,
            venvDir: SidecarSupervisor.defaultVenvDir(for: "robot-camera")
        )
        let cameraRuntime = SidecarRuntime(
            manifest: cameraManifest, resolver: cameraResolver, logBus: bus
        )
        self.robotCamera = RobotCameraService(sidecar: cameraRuntime, logBus: bus)

        // On-Mac face tracker — runs Apple's Vision face detection over the
        // camera frames and drives the TargetStreamer directly.
        self.macFaceTracker = MacFaceTracker(logBus: bus)
        self.faceLibrary = FaceLibrary(logBus: bus)

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
        // Seed the VAD with the user's calibrated threshold (or
        // 0.008 default). applySettings() will live-update it on
        // subsequent setting changes; passing it here ensures the
        // threshold is right from the very first frame, instead
        // of running 0.008 until applySettings runs.
        let vadConfig = EnergyVAD.Config(
            rmsThreshold: Float(settings.micVADThreshold)
        )
        self.voice = VoiceCoordinator(
            source: micSource, stt: self.appleSTT,
            wake: self.wakeFilter, logBus: bus,
            vad: EnergyVAD(config: vadConfig)
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

        // Memory sidecar (mempalace). Verbatim conversation drawers +
        // semantic recall — gives Rocky a persistent memory across
        // sessions instead of starting cold every launch. Optional:
        // if the venv hasn't been built yet we still hand a runtime to
        // CognitionEngine, which simply skips memory calls when the
        // sidecar fails to start.
        let memoryManifest = Self.devMempalaceManifest()
        let memoryDir = Self.locateSidecarDir(named: "mempalace")
            ?? URL(fileURLWithPath: "/")
        let memoryResolver = ManifestPathResolver(
            sidecarDir: memoryDir,
            venvDir: SidecarSupervisor.defaultVenvDir(for: "mempalace")
        )
        let memoryRuntime = SidecarRuntime(
            manifest: memoryManifest, resolver: memoryResolver, logBus: bus
        )
        self.memory = MemoryService(sidecar: memoryRuntime, logBus: bus)

        // MomentFeed — coalesces telemetry into narrative moments at
        // human cadence. Subscription is wired in start().
        self.momentFeed = MomentFeed()

        // Cognition: LM Studio client + tool registry + memory.
        self.llm = LMStudioClient(config: settings.lmStudioConfig(), logBus: bus)
        self.toolRegistry = ToolRegistry(logBus: bus)
        self.cognition = CognitionEngine(
            llm: self.llm,
            registry: self.toolRegistry,
            memory: self.memory,
            logBus: bus,
            config: .init(
                systemPrompt: settings.persona,
                memoryRecallEnabled: settings.memoryRecallEnabled,
                memoryTopK: settings.memoryTopK
            )
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

        // Memory sidecar is best-effort: if the venv hasn't been built
        // (Sidecars/mempalace/setup.sh not run), the start fails cleanly
        // and CognitionEngine just skips recall + record on subsequent
        // turns. No need to block boot on it.
        do {
            try await memory.start()
        } catch {
            await logBus.publish(.error(scope: "app/memory",
                                        message: "\(error) — run Sidecars/mempalace/setup.sh",
                                        recoverable: true))
        }

        // Pump LogBus events into MomentFeed and mirror new moments
        // back into the @Observable `recentMoments` slice for SwiftUI.
        // The two pumps run on detached Tasks so they survive any
        // restart of `start()`.
        let bus = self.logBus
        let feed = self.momentFeed
        Task { [weak self] in
            for await event in await bus.subscribe() {
                await feed.ingest(event)
                if Task.isCancelled { break }
                _ = self  // keep the closure capturing self for the
                          // weak guard above
            }
        }
        let momentsStream = await momentFeed.subscribe()
        Task { [weak self] in
            for await _ in momentsStream {
                guard let self else { return }
                let snapshot = await feed.recent(limit: 50)
                await MainActor.run { self.recentMoments = snapshot }
                if Task.isCancelled { break }
            }
        }

        // Mac-side face tracker is the source of truth for set_target now;
        // the synthetic Python detector emits useless Lissajous targets, so
        // we don't attach faceTargetBridge to its stream by default.
        await targetStreamer.start()
        await macFaceTracker.setStreamer(targetStreamer)
        // Load enrolled-face library from disk and hand it to the tracker
        // so identification runs against the user's known faces.
        await faceLibrary.loadFromDisk()
        await faceLibrary.setAcceptThreshold(settings.faceMatchThreshold)
        await robotTTS.setVolume(settings.audioVolume)
        await macFaceTracker.setLibrary(faceLibrary)
        await refreshEnrolledFaces()
        await macFaceTracker.start()

        // Mirror Mac face tracker detections + targets into observable state
        // so the dashboard reflects what the Mac detector saw.
        //
        // CRITICAL: keep main-actor mutations under 5 Hz. The detection
        // stream produces ~30 Hz; the camera, target, and state-stream
        // loops also publish to MainActor. Their combined rate determines
        // how often SwiftUI reconsiders any view that reads anything off
        // `services` — including MenuBarLabel which reads rockyState (and
        // therefore lastRobotState transitively). At >10 Hz the AppKit
        // run loop ends up too busy with SwiftUI diffs to deliver
        // keystrokes to TextFields, so typing breaks app-wide.
        let macDetections = macFaceTracker.detections
        Task { [weak self] in
            var lastMirror = Date.distantPast
            var counter = 0
            for await det in macDetections {
                guard let self else { return }
                counter += 1
                // Always run the (low-cost) greeting state machine — it
                // guards itself with a 30 s absence threshold.
                if let name = det.identity {
                    await self.handleIdentitySeen(name: name)
                }
                // Mirror to the observable surface at 5 Hz max.
                let now = Date()
                if now.timeIntervalSince(lastMirror) < 0.2 { continue }
                lastMirror = now
                let mapped = RockyVision.FaceTrackerService.Detection(
                    bbox: det.bbox,
                    confidence: det.confidence,
                    promptId: "vision-face",
                    frameWidth: det.frameWidth,
                    frameHeight: det.frameHeight,
                    identity: det.identity,
                    identityDistance: det.identityDistance,
                    closestName: det.closestName,
                    closestDistance: det.closestDistance
                )
                let snap = counter
                let now2 = Date()
                await MainActor.run {
                    self.lastFaceDetection = mapped
                    self.faceDetectionCount = snap
                    self.lastFaceDetectionAt = now2
                }
            }
        }

        // Greeting feed: every recognised name in view, primary or not,
        // routes through handleIdentitySeen. The state machine's per-name
        // 30 s absence threshold ensures a face that's been around for a
        // while doesn't get re-greeted on every cycle.
        let identitiesStream = macFaceTracker.identitiesInView
        Task { [weak self] in
            for await names in identitiesStream {
                guard let self else { return }
                for name in names {
                    await self.handleIdentitySeen(name: name)
                }
            }
        }

        // Watch the rockyState transition: pause MacFaceTracker's pushes
        // to TargetStreamer while a wake_up / goto_sleep recorded move
        // is playing — otherwise the streamer fights the primary animation.
        Task { [weak self] in
            var lastSuppressed: Bool? = nil
            while true {
                guard let self else { return }
                let suppress = await MainActor.run { () -> Bool in
                    if let until = self.transitioningUntil, Date() < until {
                        return true
                    }
                    if self.isAsleep { return true }
                    if let mode = self.lastRobotState?.controlMode,
                       mode != .enabled {
                        return true
                    }
                    return false
                }
                if suppress != lastSuppressed {
                    await self.macFaceTracker.setStreamerSuppressed(suppress)
                    await self.targetStreamer.setPrimaryMoveActive(suppress)
                    lastSuppressed = suppress
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let macTargets = macFaceTracker.targets
        Task { [weak self] in
            var lastUpdate = Date.distantPast
            var counter = 0
            for await t in macTargets {
                guard let self else { return }
                counter += 1
                let now = Date()
                // 5 Hz mirror — see detection loop for rationale.
                if now.timeIntervalSince(lastUpdate) < 0.2 { continue }
                lastUpdate = now
                let mapped = RockyVision.FaceTrackerService.Target(
                    yawRad: t.yawRad,
                    pitchRad: t.pitchRad,
                    decayActive: t.decay
                )
                let snap = counter
                await MainActor.run {
                    self.lastFaceTarget = mapped
                    self.faceTargetCount = snap
                }
            }
        }

        // (no longer needed — MacFaceTracker uses its damper state as the
        // world-frame baseline, not a lagged state-stream sample.)

        // Bring up the robot-camera sidecar (best-effort — failure means
        // the Vision card stays placeholder until next attempt).
        Task { [robotCamera, logBus] in
            do { try await robotCamera.start() }
            catch {
                await logBus.publish(.error(
                    scope: "app/robot-camera", message: "\(error)", recoverable: true
                ))
            }
        }
        // SINGLE consumer of the camera frame stream. Forwards each frame
        // to both the SwiftUI mirror AND the Mac face tracker. AsyncStream
        // is single-consumer; if the dashboard and the face tracker both
        // subscribed independently, one of them would starve.
        //
        // The face tracker gets EVERY frame (30 Hz) so detection latency is
        // honest; the SwiftUI mirror is throttled to 10 Hz so VisionCard
        // doesn't repaint a fresh JPEG 30 times a second on the main actor
        // and starve text-field keyboard handling in BrainCard.
        let cameraFrames = robotCamera.frames
        Task { [weak self] in
            var lastUiUpdate = Date.distantPast
            var counter = 0
            for await frame in cameraFrames {
                guard let self else { return }
                counter += 1
                await self.macFaceTracker.ingestFrame(frame)
                let now = Date()
                // Stamp every frame for Health stall detection — the
                // 5 Hz UI throttle below would let the row read green
                // for ~200 ms after a real stall otherwise.
                await MainActor.run { self.lastCameraFrameAt = now }
                // 5 Hz mirror — see detection loop above. The face
                // tracker still gets every frame; only the UI is throttled.
                if now.timeIntervalSince(lastUiUpdate) < 0.2 { continue }
                lastUiUpdate = now
                let snap = counter
                await MainActor.run {
                    self.lastCameraFrame = frame
                    self.cameraFrameCount = snap
                }
            }
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
        let memoryEvents = memory.sidecar.events
        Task { [weak self] in
            for await event in memoryEvents {
                if case .state(let s) = event {
                    await MainActor.run {
                        self?.memorySidecarState = s
                        // Refresh the count whenever the sidecar
                        // transitions to ready so the status panel
                        // catches up automatically.
                        if case .ready = s {
                            Task { @MainActor in await self?.refreshMemoryCount() }
                        }
                    }
                }
            }
        }

        // Pump face-tracker events into observable mirrors.
        // The Python face-tracker sidecar is still running in synthetic
        // mode but is no longer the source of truth — Mac face tracker is.
        // Drain its streams to keep them from blocking but discard the
        // events so they don't overwrite the real Mac data in the UI.
        let pyTargets = faceTracker.targets
        let pyDetections = faceTracker.detections
        Task { for await _ in pyTargets {} }
        Task { for await _ in pyDetections {} }

        // First daemon health probe. Failure is expected when the robot is off.
        Task { [weak self] in
            guard let self else { return }
            await self.probeRobot()
        }

        // Subscribe to live state. Reconnects with backoff on transport errors.
        await stateSubscriber.start()
        let states = stateSubscriber.states
        Task { [weak self] in
            // Throttle observable mutations to 5 Hz — see the detection
            // loop above for the rationale. The robot pose visualisation
            // doesn't need 10 fps; the menu bar absolutely shouldn't
            // redraw at 10 fps while the user is typing.
            var lastMirror = Date.distantPast
            var counter = 0
            for await state in states {
                guard let self else { return }
                counter += 1
                let now = Date()
                if now.timeIntervalSince(lastMirror) < 0.2 { continue }
                lastMirror = now
                let snap = counter
                await MainActor.run {
                    self.lastRobotState = state
                    self.stateUpdateCount = snap
                    if self.daemonReachability != .online {
                        self.daemonReachability = .online
                    }
                }
            }
        }

        // ONE persistent subscription to the voice coordinator's output
        // stream. AsyncStream is single-consumer; previously we spawned a
        // fresh subscriber inside every toggleMic enable, which left
        // accumulating handlers racing on the same stream and producing
        // duplicate / missed dispatches each time the user stopped and
        // started listening.
        let voiceOutputs = voice.outputs
        Task { [weak self] in
            for await output in voiceOutputs {
                guard let self else { return }
                await self.handleVoice(output)
            }
        }

        // Pat-on-head wake monitor. Polls the active mic's RMS at
        // 20 Hz; while the robot is asleep AND the mic is on, a sharp
        // transient (RMS jumps from quiet baseline to a loud spike in
        // one frame) is treated as a pat and wakes the robot. Requires
        // listen mode to be on; if you sleep with the mic muted, only
        // the Wake button works.
        Task { [weak self] in await self?.runPatMonitor() }

        // Listen mode is on by default — the user can still disable it
        // via the toggle in HeroCard / menu bar, but they shouldn't
        // have to click "Listen" to start a normal session.
        if !micEnabled { await toggleMic() }

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

    /// Refresh the STT backend label without ever showing a TCC prompt
    /// to the user. The first-run overlay's Grant access step asks
    /// for speech recognition explicitly; if we eagerly call
    /// `requestAuthorization()` here on every launch the system
    /// dialog appears under the overlay before the user gets a
    /// chance to read what's being asked. Once the user resolves
    /// the prompt (granted or denied), Apple's API guarantees
    /// subsequent `requestAuthorization()` calls return
    /// synchronously without re-prompting — so for non-`.notDetermined`
    /// statuses we still call through to update labels.
    private func warmUpSTT() async {
        let initial = SFSpeechRecognizer.authorizationStatus()
        if initial == .notDetermined {
            await MainActor.run { self.sttBackendName = "Apple Speech (pending)" }
            return
        }
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

    /// Defensive shutdown for app quit. Stops the target streamer
    /// first (no more `set_target` writes), then plays the daemon's
    /// `goto_sleep` recorded move so the head eases down before
    /// motors release — letting it free-fall would damage the
    /// neck Stewart linkage and is jarring to watch.
    /// `goToSleep()` itself handles the disable at the end of
    /// the animation; we only need a 4s budget to cover the ~2.7s
    /// move plus daemon round-trip. NSApplicationMain waits up to
    /// 5s for `reply(toApplicationShouldTerminate:)` so this fits.
    func safeShutdown() async {
        await targetStreamer.stop()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [robotLink] in
                    try await robotLink.goToSleep()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                    throw CancellationError()
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            // Best-effort. Daemon offline / timeout — fall through
            // to a hard disable so the bot doesn't keep absorbing
            // the last commanded pose. If the daemon is reachable
            // but the move fails, this still puts motors at rest;
            // if the daemon is unreachable, both calls no-op.
            try? await robotLink.setMotorMode(.disabled)
        }
        await stop()
    }

    // MARK: - Voice control

    func toggleMic() async {
        if micEnabled {
            // Stop whichever source is running.
            mic.stop()
            await robotMic.stop()
            await voice.stop()
            // Explicitly close the wake conversation window — turning off
            // listening is a clean signal that the next session should
            // start from "needs to hear Rocky again" rather than carry
            // a still-open follow-up window.
            await voice.closeConversationWindow()
            // Drain whatever the audio engine left in the ring buffer so
            // the next listen session doesn't process pre-toggle audio.
            _ = audioBuffer.drain()
            micEnabled = false
            lastMicRMS = 0
            lastMicFrameAt = nil
            lastTranscript = ""
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
                // Wake-word semantics: clicking Listen turns the mic
                // hot but the wake filter stays asleep — the user has
                // to say "Rocky" to start a conversation. Follow-ups
                // within the 60 s window don't need the wake word; the
                // window auto-closes on idle and the wake word becomes
                // required again.
                micEnabled = true
                voiceErrorMessage = nil
                // Periodic poll so the VU meter updates without
                // bouncing through the audio thread on every frame.
                // Read `useRobot` fresh each iteration rather than
                // capturing the toggle-time value — if the user
                // changes `micSource` in Settings during the
                // session, the VU meter and Health row should
                // follow the new source instead of staying frozen
                // on the old one. (Switching the actual mic input
                // source mid-session still requires a toggle
                // off-then-on cycle; this just makes the diagnostic
                // mirrors honest about which mic is live.)
                Task { [weak self] in
                    while let self, await MainActor.run(body: { self.micEnabled }) {
                        let liveUseRobot = await MainActor.run {
                            self.settings.micSource == "robot"
                        }
                        let rms: Float = liveUseRobot
                            ? await self.robotMic.lastRMS
                            : self.mic.lastRMS
                        let frameAt: Date? = liveUseRobot
                            ? await self.robotMic.lastFrameAt
                            : self.mic.lastFrameAt
                        await MainActor.run {
                            self.lastMicRMS = rms
                            self.lastMicFrameAt = frameAt
                        }
                        // 10 Hz: smooth-enough VU without thrashing redraws.
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                // Voice outputs subscription is established ONCE in
                // start() — see voiceSubscriptionTask. Spawning a new
                // subscriber per toggle was creating racing handlers
                // that double-dispatched transcripts to the LLM.
            } catch {
                voiceErrorMessage = Self.friendlyVoiceErrorMessage(for: error)
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
                // Echo gate: drop transcripts captured while Rocky is
                // speaking (or in a small tail after). Without this the
                // robot speaker bleeds into the mic, STT transcribes
                // Rocky's own voice, and every reply triggers another —
                // feedback loop. The tail covers Apple Speech's
                // post-roll latency: a final transcript from the
                // last bit of TTS audio takes ~600–1500 ms to emerge
                // from the recognizer after the audio itself has
                // stopped. 1.5 s is wide enough to catch that
                // without unduly blocking a fast user follow-up;
                // `ttsBusyUntil` itself already includes a 1.5 s
                // tail past playback end (see say handler), so the
                // total window from end-of-playback is ~3 s.
                let now = Date()
                let inEcho = ttsBusyUntil.map {
                    now < $0.addingTimeInterval(1.5)
                } ?? false
                if inEcho {
                    await logBus.publish(.sidecarLog(
                        sidecar: "voice", level: .info,
                        message: "echo gate dropped \"\(text)\"",
                        fields: [:]
                    ))
                    return
                }
                await sendUserText(text)
            }
        case .windowOpened(let until):
            await MainActor.run { self.conversationOpenUntil = until }
        case .windowClosed(let reason):
            await MainActor.run { self.conversationOpenUntil = nil }
            // "go to sleep" / "good night" / "stop listening" should
            // actually put the robot to sleep, not just close the
            // wake window. WakeFilter's stop phrases yield reason
            // "stop phrase"; the timer fires "idle timeout"; explicit
            // closes use other reasons. Only act on stop-phrase.
            let l = reason.lowercased()
            if l.contains("stop phrase") || l.contains("good night")
                 || l.contains("go to sleep") {
                await sleepRobot()
            }
        }
    }

    // MARK: - Brain

    func sendUserText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Quiet-mode gate. The menu-bar's "Pause Rocky for X" sets
        // `dndUntil`; while it's in the future, we drop user dispatches
        // so Rocky genuinely stops responding (rather than just going
        // silent on the speaker side). Still surface the message in
        // brainTurns so the user can see Rocky heard them but
        // intentionally didn't reply.
        if isDoNotDisturb {
            await MainActor.run {
                self.brainTurns.append(.init(role: "user", content: trimmed))
                let mins = max(1, Int((self.dndUntil?
                    .timeIntervalSinceNow ?? 0) / 60))
                self.brainTurns.append(.init(
                    role: "assistant",
                    content: "(quiet for \(mins) more min — won't reply until then)"
                ))
            }
            return
        }

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
            self.brainErrorMessage = nil
        }

        // Hard wall on the whole brain turn. If LM Studio stalls (or a
        // tool call inside the response wedges — `say` waiting on a
        // hung TTS sidecar is the classic case), we don't want the
        // user staring at "Routed to brain" forever. Race the event
        // loop against a timeout; whichever wins, we always reset
        // `brainBusy` and surface a message.
        let timeoutS: TimeInterval = 60
        let stream = await cognition.send(userText: trimmed)
        let timedOut = await drainBrainStream(stream, timeoutS: timeoutS)
        if timedOut {
            await MainActor.run {
                self.brainErrorMessage = "Brain didn't respond after \(Int(timeoutS))s — try again."
                self.brainTurns.append(.init(
                    role: "assistant",
                    content: "(brain timeout — reset and try again)"
                ))
            }
        }
        await MainActor.run { self.brainBusy = false }
    }

    /// Drains a CognitionEngine output stream into the observable
    /// `brainTurns`. Returns `true` if the timeout fired before the
    /// stream completed, `false` on normal completion (or non-timeout
    /// error, which is captured into `brainErrorMessage`).
    private func drainBrainStream(
        _ stream: AsyncThrowingStream<CognitionEngine.Output, Error>,
        timeoutS: TimeInterval
    ) async -> Bool {
        return await withTaskGroup(of: Bool.self) { group in
            // Drain task — owns its own local state so nothing is captured
            // mutably across the Task boundary.
            group.addTask { [weak self] in
                var assistantBuffer = ""
                var firstChunkMs: Double?
                var assistantTurnId: UUID?
                let started = Date()
                do {
                    for try await output in stream {
                        if Task.isCancelled { break }
                        guard let self else { break }
                        switch output {
                        case .assistantDelta(let delta):
                            if firstChunkMs == nil {
                                firstChunkMs = Date().timeIntervalSince(started) * 1000
                            }
                            assistantBuffer += delta
                            let snapshot = assistantBuffer
                            let f = firstChunkMs
                            let id = assistantTurnId
                            let newId: UUID = await MainActor.run { [weak self] in
                                guard let self else { return UUID() }
                                if let id, let idx = self.brainTurns.firstIndex(where: { $0.id == id }) {
                                    self.brainTurns[idx].content = snapshot
                                    return id
                                }
                                var turn = BrainTurn(role: "assistant", content: snapshot)
                                turn.firstChunkMs = f
                                self.brainTurns.append(turn)
                                return turn.id
                            }
                            assistantTurnId = newId
                        case .assistantFinal(_, let totalMs, let firstMs):
                            let id = assistantTurnId
                            let buf = assistantBuffer
                            await MainActor.run { [weak self] in
                                guard let self else { return }
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
                            await MainActor.run { [weak self] in
                                self?.brainTurns.append(.init(
                                    role: "tool", content: "→ \(name)", detail: detail
                                ))
                            }
                        case .toolCallResult(let result):
                            let summary = result.ok ? "ok" : "error"
                            let detail = result.resultJSON
                            let name = result.name
                            let ms = result.latencyMs
                            await MainActor.run { [weak self] in
                                self?.brainTurns.append(.init(
                                    role: "tool",
                                    content: "← \(name) (\(summary), \(Int(ms))ms)",
                                    detail: detail
                                ))
                            }
                        case .error(let msg):
                            await MainActor.run { [weak self] in
                                self?.brainErrorMessage = msg
                            }
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.brainErrorMessage = "\(error)"
                        self?.llmStatus = .offline(reason: "\(error)")
                    }
                }
                return false  // completed normally / errored — NOT timeout
            }
            // Timer task — fires `true` after the timeout, racing the
            // drain. Whichever finishes first wins; the other is
            // cancelled by `group.cancelAll`.
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutS * 1_000_000_000))
                return true
            }
            let winner = await group.next() ?? false
            group.cancelAll()
            return winner
        }
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

    /// Plays a short scripted head-pose gesture. Replaces the audio-bundled
    /// Pollen `play_emotion` with motion-only sequences so emotional
    /// reactions don't fire built-in sound effects. Face tracking is
    /// suppressed for the duration so the streamer doesn't fight the
    /// playback.
    ///
    /// Movement profile: deliberately slow and small. The previous pass
    /// used 0.22–0.30 s `goto` durations stacked back-to-back which read
    /// as aggressive — when a new `goto` arrives mid-motion the daemon
    /// abandons the previous trajectory, so chained short gotos look
    /// like a series of jerks. Each step here uses a generous duration
    /// AND an explicit `Task.sleep` of the same length so the motion
    /// actually completes before the next one starts.
    func playExpression(_ name: String) async throws {
        let robot = robotLink
        let neutral = RPYPose(roll: 0, pitch: 0, yaw: 0)

        /// Issue a goto and wait for the motion to actually complete
        /// before returning. A small tail (60 ms) lets the daemon
        /// settle so consecutive gotos blend rather than chain-stop.
        func step(_ pose: RPYPose, _ seconds: Double) async throws {
            try await robot.goto(headPose: pose, durationS: seconds)
            let total = UInt64((seconds + 0.06) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: total)
        }

        // Suppress face tracking + flag the avatar's "transitioning"
        // state for slightly longer than the gesture's actual length.
        let nominalDuration: TimeInterval = {
            switch name {
            case "scared":      return 1.8
            case "agree":       return 2.1
            case "disagree":    return 2.4
            case "excited":     return 2.2
            case "sad":         return 3.0
            case "curious":     return 2.0
            case "look_around": return 2.6
            case "shy":         return 2.4
            default:            return 2.0
            }
        }()
        await MainActor.run {
            self.transitioningUntil = Date().addingTimeInterval(nominalDuration + 0.3)
        }
        defer {
            Task { @MainActor in self.transitioningUntil = nil }
        }

        switch name {
        case "scared":
            // Mild pitch-back + small roll. Smaller angle and longer
            // duration than the previous "jolt" version; reads as
            // surprised rather than alarmed.
            try await step(RPYPose(roll: 0.05, pitch: -0.20, yaw: 0), 0.55)
            try? await Task.sleep(nanoseconds: 250_000_000)
            try await step(neutral, 0.80)
        case "agree":
            // One slow nod.
            try await step(RPYPose(roll: 0, pitch: 0.18, yaw: 0), 0.70)
            try await step(neutral, 0.70)
        case "disagree":
            // Single calm shake L-R-centre.
            try await step(RPYPose(roll: 0, pitch: 0, yaw: 0.20), 0.70)
            try await step(RPYPose(roll: 0, pitch: 0, yaw: -0.20), 0.80)
            try await step(neutral, 0.60)
        case "excited":
            // Slower up-and-down bob.
            try await step(RPYPose(roll: 0, pitch: -0.12, yaw: 0), 0.60)
            try await step(RPYPose(roll: 0, pitch: 0.10, yaw: 0), 0.60)
            try await step(neutral, 0.60)
        case "sad":
            // Slow droop, hold, slow recovery.
            try await step(RPYPose(roll: 0, pitch: 0.30, yaw: -0.05), 1.00)
            try? await Task.sleep(nanoseconds: 700_000_000)
            try await step(neutral, 1.00)
        case "curious":
            // Soft head tilt with a slight upward look.
            try await step(RPYPose(roll: 0.18, pitch: -0.08, yaw: 0.08), 0.80)
            try? await Task.sleep(nanoseconds: 500_000_000)
            try await step(neutral, 0.80)
        case "look_around":
            try await step(RPYPose(roll: 0, pitch: 0, yaw: 0.30), 0.85)
            try await step(RPYPose(roll: 0, pitch: 0, yaw: -0.30), 1.00)
            try await step(neutral, 0.75)
        case "shy":
            try await step(RPYPose(roll: -0.10, pitch: 0.18, yaw: 0.15), 0.85)
            try? await Task.sleep(nanoseconds: 500_000_000)
            try await step(neutral, 0.85)
        default:
            throw NSError(domain: "express", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "unknown expression: \(name)"
            ])
        }
    }

    /// Run a Rocky-voice utterance concurrently with a physical motion
    /// so the verbalisation overlaps the gesture. TTS is skipped (but
    /// motion still plays) when the user has muted output. Used by
    /// `express` and `play_emotion` to enforce the "always speak while
    /// moving" rule.
    func speakAndMove(text: String,
                      _ motion: @Sendable @escaping () async throws -> Void)
    async throws {
        let muted = await MainActor.run { self.effectiveTTSMuted }
        async let move: () = motion()
        async let speech: RobotTTS.SpeakStats? = muted
            ? nil
            : try await self.robotTTS.speak(text)
        let (_, stats) = try await (move, speech)
        if let stats {
            let until = Date().addingTimeInterval(stats.durationS + 0.2)
            await MainActor.run { self.ttsBusyUntil = until }
        }
    }

    /// Play a pre-recorded move from the Pollen emotions library
    /// (`pollen-robotics/reachy-mini-emotions-library`).
    ///
    /// **Velocity watchdog**: the daemon plays recorded moves at the
    /// authored tempo with no speed knob — once kicked off, we can't
    /// slow it down. So while it plays we sample the streaming state
    /// at 20 Hz and compute each joint's instantaneous angular
    /// velocity. If any axis exceeds
    /// `SafetyLimits.maxJointVelocityRadPerS`, the move is force-
    /// stopped. The vast majority of authored emotions stay well
    /// under the cap and play normally; only the genuinely violent
    /// ones get cut off.
    ///
    /// **Duration cap**: a separate hard ceiling on total runtime.
    /// If a move never finishes (state stream dies, daemon hangs),
    /// `stopMove` fires regardless.
    ///
    /// Suppresses face tracking for the duration so the streamer
    /// doesn't compete with the playback, and flags `transitioningUntil`
    /// so the avatar reflects the busy state.
    func playRecordedEmotion(_ name: String) async throws {
        let dataset = "pollen-robotics/reachy-mini-emotions-library"
        let safetyCap: TimeInterval = 8.0
        await MainActor.run {
            self.transitioningUntil = Date().addingTimeInterval(safetyCap)
        }
        defer {
            Task { @MainActor in self.transitioningUntil = nil }
        }
        try? await faceTracker.setEnabled(false)
        defer { Task { try? await faceTracker.setEnabled(true) } }

        try await robotLink.playRecordedMove(dataset: dataset, move: name)

        // Velocity watchdog + completion / cap loop. Sample the
        // mirrored state every 50 ms (≈20 Hz) and:
        //   - return early when the daemon reports no move running
        //   - force-stop on excessive instantaneous joint velocity
        //   - force-stop on cap timeout
        let logBus = self.logBus
        let robot = self.robotLink
        let deadline = Date().addingTimeInterval(safetyCap)
        var prevPose: RPYPose? = nil
        var prevTime = Date()
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            let now = Date()
            let dt = now.timeIntervalSince(prevTime)
            let pose = await MainActor.run { self.lastRobotState?.headPose }
            if let prev = prevPose, let cur = pose, dt > 0 {
                let dRoll  = abs(cur.roll  - prev.roll)
                let dPitch = abs(cur.pitch - prev.pitch)
                let dYaw   = abs(cur.yaw   - prev.yaw)
                let v = max(dRoll, dPitch, dYaw) / dt
                if v > SafetyLimits.maxJointVelocityRadPerS {
                    try? await robot.stopMove()
                    await logBus.publish(.error(
                        scope: "play_emotion.watchdog",
                        message: "aborted \(name): joint velocity \(String(format: "%.2f", v)) rad/s exceeded ceiling \(SafetyLimits.maxJointVelocityRadPerS)",
                        recoverable: true))
                    return
                }
            }
            prevPose = pose
            prevTime = now
            if let running = try? await robot.isMoveRunning(), !running {
                return
            }
        }
        try? await robot.stopMove()
    }

    /// Stop face tracking from pushing target events into the streamer.
    /// Mirrored on `faceTrackingEnabled` so the menu bar and main
    /// window stay in lockstep regardless of which surface toggled it.
    func setFaceTrackingEnabled(_ enabled: Bool) async {
        faceTrackingEnabled = enabled
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

    /// Tracks the last successful auto-wake so we don't spam the daemon.
    private var lastAutoWakeAt: Date?

    /// Watches mic RMS for a loud transient while sleeping, and wakes
    /// the robot when one fires. Single-tap detection: any RMS above
    /// `spikeThreshold` triggers a wake, with a 3 s cooldown so a long
    /// loud event (e.g. someone speaking nearby) doesn't fire repeatedly.
    /// The earlier "two spikes within 0.8 s" gate was rejecting too
    /// many legitimate single pats.
    private func runPatMonitor() async {
        let pollInterval: UInt64 = 50_000_000  // 50 ms (20 Hz)
        // Any audible activity wakes the robot — a chassis tap, a
        // spoken word, a clap. With the mic always-on while sleeping,
        // setting a low threshold and a cooldown gives the user
        // multiple ways to wake without false-positive runaway.
        let spikeThreshold: Float = 0.03
        let cooldownS: TimeInterval = 3.0
        var lastWakeAttempt: Date = .distantPast

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: pollInterval)
            let (asleep, micOn, useRobot) = await MainActor.run {
                (self.isAsleep,
                 self.micEnabled,
                 self.settings.micSource == "robot")
            }
            guard asleep, micOn else { continue }
            if Date().timeIntervalSince(lastWakeAttempt) < cooldownS { continue }
            let rms: Float = useRobot
                ? await self.robotMic.lastRMS
                : self.mic.lastRMS
            if rms > spikeThreshold {
                lastWakeAttempt = Date()
                await self.logBus.publish(.sidecarLog(
                    sidecar: "pat-monitor", level: .info,
                    message: "wake (rms \(String(format: "%.3f", rms)))",
                    fields: [:]
                ))
                await self.wakeRobot()
            }
        }
    }

    func wakeRobot() async {
        // wakeUp now runs two goto segments (yawn lift + settle), total
        // ~2.6–3 s of motion. transitioningUntil suppresses the face
        // tracker streamer and shows "Waking" in the UI for the duration.
        await MainActor.run {
            self.transitioningUntil = Date().addingTimeInterval(3.2)
        }
        do {
            try await robotLink.wakeUp()
            await MainActor.run { self.transitioningUntil = nil }
        } catch {
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

    /// Auto-wake Rocky if (a) the daemon is online and (b) Rocky is reported
    /// asleep. Rate-limited to once every 30 s so we don't spam if a wake
    /// fails or the user explicitly puts him back to sleep. Called from
    /// both the state stream and from the face-tracker pump (so detecting
    /// a face wakes Rocky).
    fileprivate func maybeAutoWake() async {
        guard case .online = daemonReachability else { return }
        guard isAsleep else { return }
        if let last = lastAutoWakeAt, Date().timeIntervalSince(last) < 30 {
            return
        }
        // If a wake/sleep transition is already in flight, leave it alone.
        if let until = transitioningUntil, Date() < until { return }
        lastAutoWakeAt = Date()
        await logBus.publish(.sidecarLog(
            sidecar: "app", level: .info,
            message: "auto-waking robot",
            fields: ["reason": "asleep"]
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
    /// Probe the memory sidecar for its drawer count and update the
    /// observable mirror. Surfaced in Status + Settings; safe to call
    /// at any cadence (sidecar's `count` handler is cheap).
    func refreshMemoryCount() async {
        do {
            let n = try await memory.count()
            self.memoryDrawerCount = n
        } catch {
            await logBus.publish(.error(scope: "app/memory.count",
                                         message: "\(error)",
                                         recoverable: true))
        }
    }

    /// Wipe every drawer in Rocky's palace. Wired to the destructive
    /// "Forget everything" button in Settings — call only after a
    /// confirmation dialog. Updates the observable count on success.
    @discardableResult
    func forgetAllMemory() async -> Int {
        do {
            let n = try await memory.forgetAll()
            self.memoryDrawerCount = 0
            return n
        } catch {
            await logBus.publish(.error(scope: "app/memory.forget",
                                         message: "\(error)",
                                         recoverable: true))
            return 0
        }
    }

    func applySettings() async {
        await llm.setConfig(settings.lmStudioConfig())
        await cognition.setConfig(.init(
            systemPrompt: settings.persona,
            memoryRecallEnabled: settings.memoryRecallEnabled,
            memoryTopK: settings.memoryTopK
        ))
        await faceLibrary.setAcceptThreshold(settings.faceMatchThreshold)
        await robotTTS.setVolume(settings.audioVolume)
        await voice.setVADThreshold(Float(settings.micVADThreshold))
        await probeLMStudio()
    }

    // MARK: - Tools

    private func registerInitialTools() async {
        let robot = robotLink
        let bus = logBus

        await toolRegistry.register(
            name: "look_at",
            description: "Make Rocky orient his head toward a yaw/pitch in degrees. Yaw: -180..180 (positive = left). Pitch: -40..40 (positive = down). The default duration_s is deliberately slow (1.2s) for a calm, deliberate look — only specify shorter durations if the user explicitly asks for a quick glance.",
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
                // 1.2s default — calmer than the previous 0.6s, which the
                // LLM was producing during every response and felt jerky.
                // Floor at 0.5s so the LLM can't undercut it.
                let requested = args.asObject?["duration_s"]?.asNumber ?? 1.2
                let duration = max(0.5, requested)
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

        // Full Pollen emotions library. The runtime guards
        // (velocity clamp on `goto`, real-time velocity watchdog on
        // recorded-move playback — see SafetyLimits + playRecordedEmotion)
        // catch any motion that exceeds the safe-velocity ceiling, so we
        // don't have to remove emotions from the menu to stay safe.
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

        // `play_emotion` plays a pre-baked recorded move from the
        // Pollen emotions library (much richer than the 8 scripted
        // gestures `express` has). Recorded moves include audio, so
        // the description below is explicit that this is for *direct*
        // user requests ("act scared", "do a happy dance") — not for
        // reactive emoting between sentences. `express` remains the
        // silent default for the latter.
        await toolRegistry.register(
            name: "play_emotion",
            description: """
            Play a pre-recorded full-body emotion from the Reachy emotions \
            library (head + antennas + sound) AND have Rocky verbalise at \
            the same time. Use when the user explicitly asks Rocky to \
            perform / act / show / dance / play a specific emotion. The \
            `text` Rocky speaks must follow Rocky's voice rules (telegraphic, \
            third person, no -ing/-ed) and fit the emotion. For passive \
            emotional reactions during normal conversation, use `express` \
            instead.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "enum": .array(emotions.map { .string($0) }),
                        "description": .string("Emotion identifier from the library"),
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string(
                            "What Rocky says while the move plays. Required."),
                    ]),
                ]),
                "required": .array([.string("name"), .string("text")]),
            ]),
            handler: { [weak self] args in
                guard let self,
                      let name = args.asObject?["name"]?.asString,
                      let text = args.asObject?["text"]?.asString,
                      !text.isEmpty,
                      emotions.contains(name)
                else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("missing or unknown args"),
                    ])
                }
                try await self.speakAndMove(text: text) {
                    try await self.playRecordedEmotion(name)
                }
                return .object(["ok": .bool(true), "name": .string(name)])
            }
        )

        // The custom `express` tool stays alongside `play_emotion`.
        // It produces silent scripted head-pose sequences via `goto`,
        // ~1–1.5 s each. Face tracking is suppressed for the duration
        // so the streamer doesn't fight the playback.
        let exprNames: [String] = [
            "scared", "agree", "disagree", "excited",
            "sad", "curious", "look_around", "shy",
        ]
        await toolRegistry.register(
            name: "express",
            description: """
            Make Rocky perform a short physical expression (head only, no \
            built-in audio) AND have Rocky verbalise at the same time. Use \
            when the user asks for a feeling/reaction or when it strengthens \
            what Rocky is saying. The `text` Rocky speaks must follow \
            Rocky's voice rules (telegraphic, third person, no -ing/-ed) \
            and fit the expression. Each gesture takes 1.5–3 s. \
            Available expressions: scared, agree, disagree, excited, sad, \
            curious, look_around, shy.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "enum": .array(exprNames.map { .string($0) }),
                        "description": .string("Expression to play"),
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string(
                            "What Rocky says while the expression plays. Required."),
                    ]),
                ]),
                "required": .array([.string("name"), .string("text")]),
            ]),
            handler: { [weak self] args in
                guard let self,
                      let name = args.asObject?["name"]?.asString,
                      let text = args.asObject?["text"]?.asString,
                      !text.isEmpty,
                      exprNames.contains(name) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("missing or unknown args"),
                    ])
                }
                try await self.speakAndMove(text: text) {
                    try await self.playExpression(name)
                }
                return .object(["ok": .bool(true), "name": .string(name)])
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
                let raw = args.asObject?["text"]?.asString ?? ""
                // Normalise every `say` text at the boundary —
                // strip quotes, expand `°C` / `kph` / `%` to spoken
                // form. Tools that don't pre-bake speech-friendly
                // strings, and LLMs that paraphrase with
                // abbreviations, both flow through this gate.
                let text = CognitionEngine.cleanupForTTS(raw)
                guard !text.isEmpty else {
                    return .object(["ok": .bool(false),
                                    "error": .string("empty text")])
                }
                if await MainActor.run(body: { self?.effectiveTTSMuted ?? false }) {
                    return .object(["ok": .bool(false),
                                    "error": .string("tts muted (or quiet mode)")])
                }
                // Stamp `ttsBusyUntil` BEFORE awaiting `speak` so the
                // echo gate covers the start of TTS playback. Earlier
                // code set this AFTER speak returned — by which point
                // the daemon had already begun emitting the first
                // syllables, the bot mic captured them, and STT
                // transcribed Rocky's own voice as a user follow-up.
                // Use a generous estimate based on word count
                // (~0.4 s/word, +1 s for synthesis ramp); refine to
                // the real duration once `speak` returns.
                let estimateS = max(2.0, Double(text.split(separator: " ").count) * 0.4 + 1.0)
                if let self {
                    let until = Date().addingTimeInterval(estimateS)
                    await MainActor.run { self.ttsBusyUntil = until }
                }
                let stats = try await tts.speak(text)
                // Refine the busy window with the real synth duration
                // + a 1.5 s post-roll tail. The tail covers Apple
                // Speech's STT post-processing latency: a final from
                // the last bit of TTS audio takes ~600–1500 ms to
                // emerge from the recognizer, after the audio itself
                // has stopped.
                if let self {
                    let until = Date().addingTimeInterval(stats.durationS + 1.5)
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

        // Out-of-tree tools — each lives in `Sources/Rocky/Tools/` so
        // this method doesn't keep growing. They register themselves
        // against the same `ToolRegistry` so the LLM sees them in the
        // same `tools` array as the robot-control tools above.
        await TimeTool.register(in: toolRegistry)
        let store = settings
        await WebSearchTool.register(
            in: toolRegistry,
            keyProvider: { @Sendable in
                await MainActor.run { store.braveSearchAPIKey }
            }
        )
        await RememberTool.register(in: toolRegistry, memory: memory)
        await CalendarTool.register(in: toolRegistry)
        await WeatherTool.register(in: toolRegistry)
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

    private nonisolated static func devMempalaceManifest() -> SidecarManifest {
        let venvPython = SidecarSupervisor.defaultVenvDir(for: "mempalace")
            .appendingPathComponent("bin/python")
        let dir = locateSidecarDir(named: "mempalace")?
            .path(percentEncoded: false) ?? "."
        let palacePath = (FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Rocky/Memory")
            .path(percentEncoded: false))
            ?? "~/Library/Application Support/Rocky/Memory"
        return SidecarManifest(
            name: "mempalace",
            version: "0.1.0-dev",
            binary: venvPython.path,
            args: ["-u", "-m", "rocky_mempalace.runner"],
            workingDir: dir,
            env: [
                "PYTHONPATH": dir,
                "MEMPALACE_PALACE_PATH": palacePath,
                "ROCKY_MEMORY_WING": "rocky",
                "ROCKY_MEMORY_ROOM": "conversation",
            ],
            readyTimeoutS: 60,
            shutdownGraceS: 3,
            timeouts: [
                "*": 5,
                "recall": 8,
                "add": 8,
                "init_palace": 60,
            ]
        )
    }

    private nonisolated static func devRobotCameraManifest() -> SidecarManifest {
        let venvPython = SidecarSupervisor.defaultVenvDir(for: "robot-camera")
            .appendingPathComponent("bin/python")
        let dir = locateSidecarDir(named: "robot-camera")?
            .path(percentEncoded: false) ?? "."
        return SidecarManifest(
            name: "robot-camera",
            version: "0.1.0-dev",
            binary: venvPython.path,
            args: ["-u", "-m", "rocky_robot_camera.runner"],
            workingDir: dir,
            env: [
                "PYTHONPATH": dir,
                "ROCKY_ROBOT_HOST": "reachy-mini.local",
                "ROCKY_ROBOT_PORT": "8000",
                "ROCKY_CAM_FPS": "30",
                "ROCKY_CAM_WIDTH": "384",
                "ROCKY_CAM_QUALITY": "55",
            ],
            readyTimeoutS: 30,
            shutdownGraceS: 3,
            timeouts: ["*": 10]
        )
    }

    /// Translate raw sidecar / network errors into something a user can
    /// act on. The most common failure pattern is "Reachy Mini WebRTC
    /// is single-subscriber — another client (the official Reachy app)
    /// is already connected, so our sidecar's `acquire_media()` fails
    /// with code=503 / 'Network connection attempt failed'."
    private nonisolated static func friendlyVoiceErrorMessage(for error: Error) -> String {
        let raw = "\(error)"
        let lower = raw.lowercased()
        if lower.contains("503") ||
            lower.contains("network connection") ||
            lower.contains("sidecar init failed") ||
            lower.contains("acquire_media") {
            return "Robot mic unavailable — close the official Reachy app (it holds the WebRTC stream) and try again."
        }
        if lower.contains("not authorized") ||
            lower.contains("permission") {
            return "Microphone permission denied — open System Settings → Privacy & Security → Microphone and enable Rocky."
        }
        return raw
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

    // MARK: - Face library + greeting

    func refreshEnrolledFaces() async {
        let snap = await faceLibrary.snapshot()
        self.enrolledPeople = snap.people
    }

    /// Enroll a new person from the supplied photo JPEGs. Returns the
    /// number of usable face crops the library extracted. Zero indicates
    /// none of the photos contained a detectable face.
    @discardableResult
    func enrollFace(name: String,
                    pronunciation: String,
                    photoJPEGs: [Data]) async -> Bool {
        let person = await faceLibrary.enroll(
            name: name, pronunciation: pronunciation, photoJPEGs: photoJPEGs
        )
        await refreshEnrolledFaces()
        return person != nil
    }

    func updateFace(id: UUID, name: String, pronunciation: String) async {
        await faceLibrary.update(id: id, name: name, pronunciation: pronunciation)
        await refreshEnrolledFaces()
    }

    func removeFace(id: UUID) async {
        await faceLibrary.remove(id: id)
        await refreshEnrolledFaces()
        // Forget any presence record under this person's name so the
        // next person we enroll with the same name doesn't inherit a
        // stale "recently seen" timestamp.
        personPresence.removeAll()
    }

    /// Toggle a person as the primary face Rocky tracks. Passing nil
    /// (or the same id that's currently primary) clears the primary,
    /// reverting tracking to "follow the largest face in view".
    func setPrimaryFace(id: UUID?) async {
        await faceLibrary.setPrimary(id: id)
        await refreshEnrolledFaces()
    }

    /// Called from the face-detection stream whenever a recognised name
    /// is in view. Drives the per-person "absent → present" transition
    /// and triggers a TTS greeting on re-entry.
    private func handleIdentitySeen(name: String) async {
        let now = Date()
        let lastSeen = personPresence[name]
        let wasAbsent = lastSeen.map {
            now.timeIntervalSince($0) > presenceAbsenceThreshold
        } ?? true
        personPresence[name] = now
        guard wasAbsent else { return }

        // Don't greet from a sleeping or muted/busy state — Rocky should
        // be present and able to speak.
        guard rockyState.isAwake else { return }
        if effectiveTTSMuted { return }
        if brainBusy { return }
        if let until = ttsBusyUntil, now < until { return }

        let pronunciation = enrolledPeople.first(where: { $0.name == name })?
            .spokenName ?? name

        // Pick a phrase, avoiding immediate repetition of the last one.
        let templates = Self.greetingTemplates
        var idx = Int.random(in: 0..<templates.count)
        if templates.count > 1, let last = lastGreetingIndex, last == idx {
            idx = (idx + 1) % templates.count
        }
        lastGreetingIndex = idx
        let phrase = templates[idx]
            .replacingOccurrences(of: "{name}", with: pronunciation)

        // Tag a busy window so concurrent "speaking" gating in
        // rockyState reflects the greeting and we don't overlap with a
        // dispatched LLM reply.
        ttsBusyUntil = now.addingTimeInterval(3.0)
        await logBus.publish(.sidecarLog(
            sidecar: "greeting", level: .info,
            message: "greeting \(name) — \"\(phrase)\"",
            fields: [:]
        ))
        Task { [robotTTS, logBus] in
            do {
                _ = try await robotTTS.speak(phrase)
            } catch {
                await logBus.publish(.error(
                    scope: "greeting", message: "\(error)", recoverable: true
                ))
            }
        }
    }
}
