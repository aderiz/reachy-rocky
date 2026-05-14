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
    /// Single chokepoint for every motion command. Wraps `robotLink`
    /// with slew-rate, velocity, duration-floor, single-in-flight,
    /// and shelf-safety guards. NEW callsites must go through this,
    /// not `robotLink` directly — the latter bypasses all safety.
    let motionGuard: MotionGuard
    let supervisor: SidecarSupervisor
    let targetStreamer: TargetStreamer
    let robotCamera: RobotCameraService
    let macFaceTracker: MacFaceTracker
    let faceLibrary: FaceLibrary
    let stateSubscriber: StateSubscriber
    let wakeEngine: any WakeWordEngine
    /// Polls the on-bot media relay's `/battery` endpoint. Independent
    /// of daemon reachability so a paused camera or dead daemon
    /// doesn't blank the chip.
    let battery: BatteryService
    /// Native-MLX brain sidecar runtime, or nil when the venv hasn't
    /// been installed (`Sidecars/brain/setup.sh`). When nil,
    /// CognitionEngine uses the LMStudioBrain (HTTP) fallback.
    let brainSidecar: SidecarRuntime?
    /// MLX-Whisper STT sidecar runtime, or nil when its venv hasn't
    /// been built (`Sidecars/mlx-stt/setup.sh`). When nil, warmUpSTT
    /// falls back to WhisperKit (CoreML) and then Apple Speech.
    let mlxSTTSidecar: SidecarRuntime?
    /// M6 streaming TTS player. Receives PCM chunks from
    /// Qwen3-TTS-12Hz and plays them via `AVAudioEngine`.
    let streamingTTS: StreamingTTS

    /// End-to-end turn profiler. Subscribes to LogBus, builds a
    /// per-turn `TurnProfile`, pushes it to `profileStore` and emits
    /// a `.turnProfile` log event. Off by default — flip in Settings.
    let turnProfiler: TurnProfiler
    /// Rolling buffer of recent `TurnProfile`s for the Inspector →
    /// Profile tab to render as a waterfall.
    let profileStore: ProfileStore

    // Voice
    let audioBuffer: AudioRingBuffer
    let mic: MicService
    let robotMic: RobotMicService
    let wakeFilter: WakeFilter
    let voice: VoiceCoordinator
    /// Strict post-STT "is this addressed to Rocky?" filter that
    /// gates brain dispatch on multiple signals (loudness vs. room
    /// noise, DoA from the on-bot mic array, face engagement, STT
    /// confidence, junk-phrase list). See `Sources/Voice/AddressFilter.swift`
    /// and the plan at `~/.claude/plans/sprightly-forging-zebra.md`.
    let addressFilter: AddressFilter
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

    /// Latest battery snapshot from the on-bot media relay. `nil` until
    /// the first poll lands. The relay returns `present: false` on bots
    /// whose image doesn't expose the BMS to userspace — distinct from
    /// `nil` (haven't asked yet) and from `reachable: false` (relay
    /// unreachable).
    var latestBattery: BatteryService.Snapshot?

    /// Live mirror of the latest face-tracker target so the Vision card can render it.
    var lastFaceTarget: FaceTargetSnapshot?
    var lastFaceDetection: MacFaceTracker.Detection?
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

    /// Whether the camera frame is forwarded to the brain on each chat
    /// turn. When `false`, the `imageProvider` closure returns nil so
    /// the VLM operates text-only — useful for privacy (don't share
    /// the room with the model) or when the camera frame is distracting
    /// the model. The camera sidecar keeps running so the face tracker
    /// and Vision card still work; only the brain feed is gated.
    var visionEnabled: Bool = true

    /// Sidecar lifecycle mirrors so the Status panel can render real states
    /// without poking actors on every redraw.
    var ttsSidecarState: SidecarState = .stopped
    var memorySidecarState: SidecarState = .stopped
    var brainSidecarState: SidecarState = .stopped

    /// Per-sidecar warmup progress. SidecarState only swings between
    /// `.starting` and `.ready`, but on heavy MLX models there's a
    /// 5–30 s gap between "process spawned" and "first inference is
    /// fast", broken into two phases the user cares about: weights
    /// loading from disk, then the first JIT pass. We collect this
    /// per sidecar so StatusView can render a progress cue ("loading
    /// model…" → "warming…" → "warm · 6.3 s") instead of a static
    /// "starting…" for the whole interval. Phase strings come from
    /// the runners' `emit_log(...phase=...)` field, decoded in
    /// `pumpWarmupPhases()`.
    enum WarmupPhase: Equatable, Sendable {
        case idle
        case loading            // model weights deserializing
        case warming            // weights loaded; first JIT pass in flight
        case ready(loadMs: Int?, warmMs: Int?)
        case failed(reason: String)
    }
    var warmupPhases: [String: WarmupPhase] = [
        "brain": .idle, "mlx-stt": .idle,
        "mlx-tts": .idle, "mempalace": .idle,
    ]

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
        // Brain offline is amber-not-fatal. Only flag it when the
        // *active* backend is unreachable — LM Studio being offline
        // is fine when MLX-VLM is in charge.
        switch settings.brainBackend {
        case "lm-studio":
            if case .offline(let reason) = llmStatus {
                return HealthGlance(
                    label: "Brain offline",
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    tooltip: "LM Studio offline — \(reason)"
                )
            }
        case "mlx-vlm":
            switch brainSidecarState {
            case .stopped, .failing, .circuitOpen:
                return HealthGlance(
                    label: "Brain offline",
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    tooltip: "MLX-VLM brain — \(brainStateHumanReadable())"
                )
            case .ready, .starting:
                break
            }
        default: // "auto"
            let mlxReady = brainSidecarState == .ready
            let lmReady: Bool = { if case .online = llmStatus { return true }; return false }()
            if !mlxReady, !lmReady {
                return HealthGlance(
                    label: "Brain offline",
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    tooltip: "No brain backend ready — \(brainStateHumanReadable())"
                )
            }
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
        self.motionGuard = MotionGuard(client: self.robotLink, logBus: bus)
        self.supervisor = SidecarSupervisor(logBus: bus)
        self.stateSubscriber = StateSubscriber(endpoint: endpoint, logBus: bus)
        // Battery polls the on-bot media relay on port 8042, not the
        // daemon — see OnBot/rocky_media_relay for the `/battery`
        // endpoint contract. Reusing robotHost is correct (the relay
        // and daemon share the bot's hostname).
        self.battery = BatteryService(
            host: endpoint.host, port: 8042, logBus: bus
        )

        // 50 Hz set_target streamer. Targets come from `MacFaceTracker`
        // (Apple Vision face detection on `robot-camera` JPEG frames);
        // the streamer is suppressed during recorded primary moves.
        self.targetStreamer = TargetStreamer(client: self.motionGuard, logBus: bus)

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
        // Configurable wake phrase from Settings (default "rocky"
        // matches the persona name). Stored lowercase; WakeFilter
        // already lowercases on match.
        self.wakeFilter = WakeFilter(
            config: WakeFilter.Config(
                wakeName: settings.wakeWord,
                conversationWindowS: settings.convoWindowS
            )
        )
        // AddressFilter — initialised from the user's persisted
        // calibration values. `applyAddressFilterCalibration()`
        // hot-applies updates when the user re-runs the mic
        // calibration flow or moves a Settings slider.
        self.addressFilter = AddressFilter(
            config: AddressFilter.Config(
                enabled: settings.addressFilterEnabled,
                minSttConfidence: settings.addressMinSttConfidence,
                rmsFloor: settings.addressRMSFloor,
                loudnessRatio: settings.addressLoudnessRatio,
                userDoaCenterRad: settings.addressUserDoaCenterRad,
                userDoaToleranceRad: settings.addressUserDoaToleranceRad,
                faceEngageWindowS: settings.addressFaceEngageWindowS,
                junkPhrases: settings.addressJunkPhrases,
                verbPrefixes: settings.addressVerbPrefixes
            )
        )
        // Wake-word engine — STT-derived by default, Porcupine stub
        // when the user opts in. The factory logs a warning if
        // "porcupine" is selected but the implementation isn't
        // available yet, then falls back to STT.
        self.wakeEngine = Self.makeWakeEngine(
            engine: settings.wakeEngine,
            logBus: bus
        )
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
        // Pick the VAD engine per `settings.vadEngine`:
        //   - "auto"   -> Silero if its CoreML model is installed, else Energy.
        //   - "silero" -> Silero, falling back to Energy with a warning.
        //   - "energy" -> the simple RMS detector.
        // Energy stays as the failsafe (zero deps, always works); Silero
        // is the v0.2 default once the 1-MB CoreML model from
        // `scripts/download-models.sh` is on disk.
        let chosenVAD: any VAD = Self.makeVAD(
            engine: settings.vadEngine,
            energyThreshold: Float(settings.micVADThreshold),
            logBus: bus
        )
        self.voice = VoiceCoordinator(
            source: micSource, stt: self.appleSTT,
            wake: self.wakeFilter, logBus: bus,
            vad: chosenVAD
        )

        // Voice out (TTS): mlx-tts sidecar. `say` backend uses /usr/bin/python3
        // and zero deps; `chatterbox` requires the [mlx] venv built via
        // `FT_EXTRAS=mlx ./Sidecars/mlx-tts/setup.sh` and runs Chatterbox
        // Turbo FP16 with the user's voice reference.
        self.mediaClient = MediaClient(endpoint: endpoint, logBus: bus)
        let ttsManifest = Self.devTTSManifest(
            backend: settings.ttsBackend,
            model: settings.ttsModel
        )
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
        // M6 streaming player. Default target: Mac local audio
        // (lowest first-chunk latency). RobotTTS picks the streaming
        // path when the sidecar reports `streams: true` in health
        // — Qwen3-TTS-12Hz does, Chatterbox doesn't.
        self.streamingTTS = StreamingTTS(logBus: bus)

        // End-to-end profiler. Always instantiated so the toggle in
        // Settings can flip it without restarting; gated by
        // `SettingsStore.profilingEnabled` via `applyProfiling()`.
        self.profileStore = ProfileStore(capacity: 50)
        self.turnProfiler = TurnProfiler(logBus: bus, store: self.profileStore)

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

        // Cognition: brain backend + tool registry + memory. The
        // LM Studio HTTP client always exists as the v0.1 fallback;
        // M5 layers MLXVLMBrain (mlx-vlm + Qwen3-VL 4B sidecar) as
        // the v0.2 default. The brain sidecar is constructed below
        // and selected on top of LMStudioBrain in `start()`.
        self.llm = LMStudioClient(config: settings.lmStudioConfig(), logBus: bus)
        self.toolRegistry = ToolRegistry(logBus: bus)
        let initialBrain: any BrainBackend = LMStudioBrain(client: self.llm)

        // Brain sidecar — only initialised when the venv exists.
        // First-run users without the venv get LMStudioBrain (text-
        // only HTTP) until they run `Sidecars/brain/setup.sh`.
        let brainVenv = SidecarSupervisor.defaultVenvDir(for: "brain")
            .appendingPathComponent("bin/python")
        if FileManager.default.fileExists(atPath: brainVenv.path),
           let brainDir = Self.locateSidecarDir(named: "brain") {
            let brainManifest = SidecarManifest(
                name: "brain",
                version: "0.2.0",
                binary: brainVenv.path,
                args: ["-u", "-m", "rocky_brain.runner"],
                workingDir: brainDir.path(percentEncoded: false),
                env: [
                    "PYTHONPATH": brainDir.path(percentEncoded: false),
                    "ROCKY_BRAIN_MODEL": settings.brainModel,
                ],
                readyTimeoutS: 300,
                shutdownGraceS: 5,
                timeouts: ["*": 5, "chat_stream": 120, "set_model": 300]
            )
            let brainResolver = ManifestPathResolver(
                sidecarDir: brainDir,
                venvDir: SidecarSupervisor.defaultVenvDir(for: "brain")
            )
            self.brainSidecar = SidecarRuntime(
                manifest: brainManifest, resolver: brainResolver, logBus: bus
            )
        } else {
            self.brainSidecar = nil
        }

        // MLX-Whisper STT sidecar. Same pattern as brain: only built
        // when the venv exists, so first-run users without it land
        // on WhisperKit / Apple Speech via `warmUpSTT`.
        let mlxSTTVenv = SidecarSupervisor.defaultVenvDir(for: "mlx-stt")
            .appendingPathComponent("bin/python")
        if FileManager.default.fileExists(atPath: mlxSTTVenv.path),
           let sttDir = Self.locateSidecarDir(named: "mlx-stt") {
            let sttManifest = SidecarManifest(
                name: "mlx-stt",
                version: "0.1.0",
                binary: mlxSTTVenv.path,
                args: ["-u", "-m", "rocky_mlx_stt.runner"],
                workingDir: sttDir.path(percentEncoded: false),
                env: [
                    "PYTHONPATH": sttDir.path(percentEncoded: false),
                    // Sidecar default falls back to whisper-small-mlx
                    // if this is unset; leave unset here so the
                    // sidecar's own default (kept in one place,
                    // runner.py) is the source of truth. Users who
                    // want a bigger model set ROCKY_STT_MODEL in
                    // their shell env before launching the app.
                    "ROCKY_STT_LANGUAGE": "en",
                ],
                readyTimeoutS: 300,
                shutdownGraceS: 5,
                // First transcribe loads the model (~5 s); cap the
                // RPC at 30 s so a stuck call surfaces clearly. warm_up
                // gets a longer budget for the explicit model fetch.
                timeouts: ["*": 5, "transcribe": 30, "warm_up": 60]
            )
            let sttResolver = ManifestPathResolver(
                sidecarDir: sttDir,
                venvDir: SidecarSupervisor.defaultVenvDir(for: "mlx-stt")
            )
            self.mlxSTTSidecar = SidecarRuntime(
                manifest: sttManifest, resolver: sttResolver, logBus: bus
            )
        } else {
            self.mlxSTTSidecar = nil
        }

        self.cognition = CognitionEngine(
            brain: initialBrain,
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
        // LogBus pumps must subscribe BEFORE any sidecar boots —
        // `LogBus.subscribe()` does not replay events to late
        // subscribers, so a pump set up after `applyBrainBackend()`
        // misses every `phase=load_start|load_done|warm_done` event
        // the brain runner emits during its load+warmup window.
        // That's why Health used to show a bare "ready · <model>"
        // with no spinner — the phase dictionary stayed at `.idle`
        // the whole time. Setting up here guarantees the
        // visualization tracks the actual lifecycle.
        let bus = self.logBus
        let feed = self.momentFeed

        // Pump 1: warmup-phase events. Decodes the `phase` field on
        // sidecar log lines and updates `warmupPhases` so StatusView
        // can render a phase-aware subtitle + pulsing spinner.
        Task { [weak self] in
            for await stamped in await bus.subscribe() {
                guard let self else { break }
                if case .sidecarLog(let name, _, _, let fields) = stamped.event,
                   let phase = fields["phase"] {
                    let loadMs = fields["load_time_ms"].flatMap(Int.init)
                    let warmMs = fields["warmup_ms"].flatMap(Int.init)
                    let reason = fields["error"]
                    await MainActor.run {
                        self.applyWarmupPhase(
                            sidecar: name, phase: phase,
                            loadMs: loadMs, warmMs: warmMs,
                            reason: reason
                        )
                    }
                }
                if Task.isCancelled { break }
            }
        }

        // Pump 2: MomentFeed ingest + the `recentMoments` mirror.
        // Both pumps run on independent tasks because each
        // `bus.subscribe()` returns its own channel — sharing one
        // would couple feed-ingest cadence to phase-update cadence.
        Task { [weak self] in
            for await event in await bus.subscribe() {
                await feed.ingest(event)
                if Task.isCancelled { break }
                _ = self
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

        // Memory sidecar is best-effort: if the venv hasn't been built
        // (Sidecars/mempalace/setup.sh not run), the start fails cleanly
        // and CognitionEngine just skips recall + record on subsequent
        // turns. No need to block boot on it.
        do {
            try await memory.start()
            // Warm the embedding model BEFORE returning from start()
            // so the user's first recall doesn't pay the ChromaDB
            // lazy-init cost (~1.5–3 s for the COREML providers to
            // load). Earlier attempt used a detached task; that
            // raced against the user's first turn and the recall
            // still timed out under fast launches. Synchronous
            // here adds ~2 s to app startup but guarantees recall
            // is hot before the brain sees a query. Failures are
            // non-fatal — fall through with logging and the
            // existing 4 s timeout in CognitionEngine still gates.
            let started = Date()
            do {
                _ = try await memory.initPalace()
                _ = try await memory.recall(query: "warm-up", k: 1)
                let ms = Date().timeIntervalSince(started) * 1000
                await logBus.publish(.sidecarLog(
                    sidecar: "mempalace", level: .info,
                    message: String(format: "embedding model warm in %.0f ms", ms),
                    fields: [:]
                ))
            } catch {
                await logBus.publish(.sidecarLog(
                    sidecar: "mempalace", level: .warn,
                    message: "warm-up failed: \(error)",
                    fields: [:]
                ))
            }
            // One-shot v2 migration: bin any drawers stored under the
            // pre-v2 wings (`default/default`, `rocky/conversation`).
            // The user explicitly asked for "bin them" — we don't try
            // to remap legacy entries into the new office/dated-room
            // layout, just delete and let the new flow build fresh.
            // Persistent flag in UserDefaults so the wipe runs exactly
            // once across all future launches.
            let migrationKey = "rocky.memory.v2-migration"
            if !UserDefaults.standard.bool(forKey: migrationKey) {
                do {
                    let deleted = try await memory.wipeLegacy()
                    UserDefaults.standard.set(true, forKey: migrationKey)
                    await logBus.publish(.sidecarLog(
                        sidecar: "mempalace", level: .info,
                        message: "v2 migration: wiped \(deleted) legacy drawer(s)",
                        fields: [:]
                    ))
                } catch {
                    await logBus.publish(.sidecarLog(
                        sidecar: "mempalace", level: .warn,
                        message: "v2 migration failed: \(error)",
                        fields: [:]
                    ))
                }
            }
        } catch {
            await logBus.publish(.error(scope: "app/memory",
                                        message: "\(error) — run Sidecars/mempalace/setup.sh",
                                        recoverable: true))
        }

        // Brain backend — applies whichever backend the user chose
        // (default "auto" picks MLX-VLM if the venv is installed).
        // Settings UI's "Apply" button calls applyBrainBackend()
        // to hot-swap without restarting Rocky.
        await applyBrainBackend()

        // Brain pre-warm. The MLX-VLM sidecar runs its own three-pass
        // warmup inside `Brain.load()` BEFORE emitting `ready`, using
        // a long synthetic prompt + 384×384 image + tool schema to
        // shape-match the user's real first query. By the time
        // `applyBrainBackend()` returned above, kernels for the
        // long-prefill + vision + tool path should all be JIT'd.
        //
        // This Swift-side probe finishes the job with the *actual*
        // persona, tool schemas, and (if vision is on) the latest
        // camera frame — exactly the path `CognitionEngine.runStream`
        // takes for the user's first query. Any shape the sidecar's
        // synthetic warmup missed gets paid here, on the
        // wallclock-tolerant startup path instead of on turn 1.
        //
        // `.userInitiated` so the scheduler doesn't starve it behind
        // the user's first dispatch (a `.utility` detached task lost
        // that race in production).
        let warmBrain = await cognition.brain
        let warmBus = logBus
        let warmPersona = settings.persona
        let warmTools = await toolRegistry.schemas
        Task.detached(priority: .userInitiated) {
            let started = Date()
            // Critically: NO image attached. The brain's chat_stream
            // uses fresh per-call caches whenever an image is present
            // (vision tokens hash per-frame, so cache reuse risks a
            // shape mismatch). With no image, it uses the persistent
            // `self.prompt_cache_state` and POPULATES it with the
            // persona + tool-schema prefix as a side-effect of this
            // warmup call. The user's first real text-only query
            // then finds the matching prefix in the cache and skips
            // the ~8 s of persona + tools prefill that would
            // otherwise dominate turn 1.
            //
            // Image-bearing first queries don't benefit from this
            // (they take the fresh-cache path) — they pay full
            // prefill on turn 1. That's an inherent trade-off of
            // dynamic-resolution VLM cache invalidation; we
            // optimise for the common case (knowledge queries,
            // tool-using queries without vision) where cache reuse
            // pays for itself many times over.
            //
            // Mirror the message shape `CognitionEngine.runStream`
            // produces: system persona, then a single user message.
            // The user message text doesn't matter — only its
            // presence does, since the cache is keyed on tokens.
            // We pick something very short ("hi") so the token
            // sequence after the persona+tools prefix is minimal,
            // and the cache holds the persona+tools portion that's
            // actually reusable.
            let messages: [ChatMessage] = [
                .init(role: .system, content: warmPersona),
                .init(role: .user, content: "hi"),
            ]
            let stream = warmBrain.chatStream(
                messages: messages,
                tools: warmTools.isEmpty ? nil : warmTools,
                image: nil
            )
            do {
                for try await _ in stream {
                    // Read one token to confirm prefill+decode hot,
                    // then bail. The response content is discarded.
                    break
                }
                let ms = Date().timeIntervalSince(started) * 1000
                await warmBus.publish(.sidecarLog(
                    sidecar: "brain", level: .info,
                    message: String(
                        format: "prompt-cache primed in %.0f ms (persona + %d tools)",
                        ms, warmTools.count
                    ),
                    fields: [
                        "phase": "warm_done_swift",
                        "warmup_ms": "\(Int(ms))",
                    ]
                ))
            } catch {
                await warmBus.publish(.sidecarLog(
                    sidecar: "brain", level: .warn,
                    message: "shape-matched warm failed: \(error)",
                    fields: [:]
                ))
            }
        }

        // (LogBus pumps for warmup-phase + MomentFeed were set up at
        // the top of start() to catch sidecar events from the very
        // first emit. See the comment block there.)

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
        await macFaceTracker.setIdleSearchEnabled(settings.faceTrackerIdleSearchEnabled)
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
                let snap = counter
                let now2 = Date()
                await MainActor.run {
                    self.lastFaceDetection = det
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

        // Watch the rockyState transition and propagate wake state to
        // the face tracker. Two distinct gates with the same source:
        //
        //   • `setStreamerSuppressed(true)` — block 50 Hz set_target
        //     pushes so the streamer doesn't fight a primary animation
        //     mid-wake/sleep or generate targets while motors are off.
        //   • `setSleeping(true)` — stop frame ingestion + idle search
        //     so the Vision pipeline isn't burning CPU producing
        //     detections that the (sleeping) motors will never act on.
        //
        // The user constraint: face tracker is only active when the
        // bot is awake. `isAsleep` is the canonical wake-state flag;
        // it covers both explicit sleepRobot() calls and the boot
        // case where the robot was already powered-down before app
        // launch. `transitioningUntil` and `controlMode != .enabled`
        // are extra reasons to suppress the streamer specifically
        // (motors transitioning or compliant) — they don't imply
        // "stop Vision compute," so they only affect the streamer
        // gate.
        Task { [weak self] in
            var lastSuppressed: Bool? = nil
            var lastSleeping: Bool? = nil
            while true {
                guard let self else { return }
                let (sleeping, suppress) = await MainActor.run { () -> (Bool, Bool) in
                    let asleep = self.isAsleep
                    let transitioning = (self.transitioningUntil.map { Date() < $0 }) ?? false
                    let modeBlock = (self.lastRobotState?.controlMode).map { $0 != .enabled } ?? false
                    let suppress = asleep || transitioning || modeBlock
                    return (asleep, suppress)
                }
                if suppress != lastSuppressed {
                    await self.macFaceTracker.setStreamerSuppressed(suppress)
                    await self.targetStreamer.setPrimaryMoveActive(suppress)
                    lastSuppressed = suppress
                }
                if sleeping != lastSleeping {
                    await self.macFaceTracker.setSleeping(sleeping)
                    lastSleeping = sleeping
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
                let mapped = FaceTargetSnapshot(
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
        Task { [robotTTS, streamingTTS, logBus] in
            do {
                try await robotTTS.start()
                // Wire the streaming player so RobotTTS routes through
                // speakStreaming when the sidecar exposes streams.
                await robotTTS.setStreamingPlayer(streamingTTS)
            } catch {
                await logBus.publish(.error(
                    scope: "app/mlx-tts", message: "\(error)", recoverable: true
                ))
            }
        }
        // Mirror StreamingTTS.isSpeakingStream into ttsBusyUntil so the
        // echo gate has a ground-truth busy signal.
        //
        // Critical: when `isSpeaking` flips false, we DON'T clear
        // `ttsBusyUntil` to nil — we stamp it `Date() + 1.5 s` instead.
        // AddressFilter's `ttsActive` check is
        //   `now < ttsBusyUntil.addingTimeInterval(1.5)`
        // which returns `false` for a nil `ttsBusyUntil` — meaning the
        // grace window collapses to zero the instant the audio
        // duration timer fires. STT segments captured while Rocky was
        // talking finalize ~500 ms later and end up dispatched as
        // "user input" (echo hallucinations: "One of Rocky's love
        // love love…"). Keeping `ttsBusyUntil` 1.5 s in the future +
        // AddressFilter's own 1.5 s grace = 3 s of post-Rocky echo
        // suppression, matching the v0.1 explicit-stamp behaviour.
        let speakingStream = streamingTTS.isSpeakingStream
        let wakeFilterForSpeaking = wakeFilter
        Task { [weak self] in
            for await speaking in speakingStream {
                await MainActor.run {
                    if speaking {
                        self?.ttsBusyUntil = Date.distantFuture
                    } else {
                        self?.ttsBusyUntil = Date().addingTimeInterval(1.5)
                    }
                }
                // When Rocky finishes speaking, RESET the conversation
                // window so the user gets the full `convoWindowS` from
                // *now* to reply — not whatever's left from when they
                // first said "Rocky". Without this, a 30 s response
                // from Rocky inside a 20 s window means the user has
                // to say the wake name again to follow up.
                //
                // Uses `keepAliveAfterSpeaking` (not `extendOnEngaged`)
                // so the reset works even when the original window
                // already expired during Rocky's long response.
                if !speaking, let self {
                    let until = await wakeFilterForSpeaking.keepAliveAfterSpeaking()
                    await MainActor.run {
                        self.conversationOpenUntil = until
                    }
                    await self.logBus.publish(.conversationWindow(
                        transition: .opened, reason: "rocky finished speaking"
                    ))
                }
            }
        }

        // Mirror sidecar state into Observable so the Status panel can read it.
        let ttsEvents = robotTTS.sidecar.events
        let ttsSidecar = robotTTS.sidecar
        Task { [weak self] in
            for await event in ttsEvents {
                if case .state(let s) = event {
                    await MainActor.run {
                        self?.ttsSidecarState = s
                        self?.reconcileWarmupOnStateChange(sidecar: "mlx-tts", state: s)
                    }
                    if case .ready = s, let self {
                        await self.refreshWarmupFromHealth(
                            name: "mlx-tts", sidecar: ttsSidecar
                        )
                    }
                }
            }
        }
        let memoryEvents = memory.sidecar.events
        Task { [weak self] in
            for await event in memoryEvents {
                if case .state(let s) = event {
                    await MainActor.run {
                        self?.memorySidecarState = s
                        self?.reconcileWarmupOnStateChange(sidecar: "mempalace", state: s)
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
        // Mirror brain sidecar state into the Observable so the
        // Settings → Brain tab can render Ready / Starting /
        // Failing without poking the actor on every redraw.
        if let brainSidecar {
            let brainEvents = brainSidecar.events
            Task { [weak self] in
                for await event in brainEvents {
                    if case .state(let s) = event {
                        await MainActor.run {
                            self?.brainSidecarState = s
                            self?.reconcileWarmupOnStateChange(sidecar: "brain", state: s)
                        }
                        // Pull-based warmup snapshot — bypasses the
                        // log-event race. When the sidecar
                        // transitions to .ready, call `health` to
                        // fetch the load + warmup timings the
                        // runner cached during its load+warm_up
                        // sequence. The Health view's "warm · load
                        // Xs + JIT Ys" cue then renders from this
                        // deterministic round-trip instead of from
                        // log lines that may or may not have
                        // reached LogBus subscribers in time.
                        if case .ready = s, let self {
                            await self.refreshBrainWarmupFromHealth()
                        }
                    }
                }
            }
        }
        if let mlxSTTSidecar {
            let sttEvents = mlxSTTSidecar.events
            let sttSidecar = mlxSTTSidecar
            Task { [weak self] in
                for await event in sttEvents {
                    if case .state(let s) = event {
                        await MainActor.run {
                            self?.reconcileWarmupOnStateChange(sidecar: "mlx-stt", state: s)
                        }
                        if case .ready = s, let self {
                            await self.refreshWarmupFromHealth(
                                name: "mlx-stt", sidecar: sttSidecar
                            )
                        }
                    }
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
        // 20 Hz; while the robot is asleep AND the mic is on AND
        // SettingsStore.wakeOnPat is true, a loud transient wakes the
        // robot. Off by default — the on-robot mic hears Rocky's own
        // goodnight TTS / fans / ambient voice and trips immediately.
        Task { [weak self] in await self?.runPatMonitor() }

        // Listen mode is on by default — the user can still disable it
        // via the toggle in HeroCard / menu bar, but they shouldn't
        // have to click "Listen" to start a normal session.
        fputs("[mic] auto-toggle on at app start (micEnabled=\(micEnabled))\n", stderr)
        if !micEnabled { await toggleMic() }
        fputs("[mic] auto-toggle complete (micEnabled=\(micEnabled), source=\(settings.micSource), err=\(voiceErrorMessage ?? "none"))\n", stderr)

        // On-bot relay auto-start. The Reachy Mini daemon doesn't
        // remember "the last running app" across reboots — after a
        // power-cycle, `current-app-status` is null and our mic /
        // camera sidecars will spin in their reconnect loops
        // forever. Wait for the daemon to come online, then ensure
        // `rocky_media_relay` is the active app. Fire-and-forget so
        // it doesn't gate the rest of startup.
        Task { [weak self] in await self?.ensureRelayAppRunning() }

        // Start the battery poller (relay endpoint at port 8042) and
        // mirror its snapshots onto the @Observable surface. Mirroring
        // happens on the main actor because @Observable property
        // mutations must publish on the actor that owns the @Observable.
        await battery.start()
        let batteryStream = self.battery.snapshots
        Task { [weak self] in
            for await snap in batteryStream {
                await MainActor.run {
                    self?.latestBattery = snap
                }
            }
        }

        // Tool registry + LM Studio probe. Auto-retries every 8 s while
        // status is offline so users don't have to click "Probe" after
        // launching LM Studio.
        await registerInitialTools()

        // M7 fast-path. Build the FastPath matcher with handlers
        // backed by the tools we just registered. The fast-path
        // dispatches them directly for trivial queries (time,
        // weather, calendar, search, remember, greeting), bypassing
        // the brain — sub-second time-to-first-word.
        let fastPath = await Self.makeFastPath(
            registry: self.toolRegistry, logBus: self.logBus
        )
        await cognition.setFastPath(fastPath)
        Task { [weak self] in await self?.probeLMStudio() }
        Task { [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                // Only probe LM Studio when it's the active brain
                // (or "auto" with MLX-VLM not ready). Otherwise the
                // 8-second poll keeps hitting a closed port and
                // surfacing irrelevant offline errors.
                let shouldProbe: Bool = await MainActor.run {
                    let pref = self.settings.brainBackend
                    if pref == "mlx-vlm" { return false }
                    if pref == "auto", self.brainSidecarState == .ready {
                        return false
                    }
                    if case .offline = self.llmStatus { return true }
                    return false
                }
                if shouldProbe { await self.probeLMStudio() }
            }
        }

        // Speech recognition authorization.
        Task { [weak self] in await self?.warmUpSTT() }

        // TurnProfiler: bring up the LogBus subscription if the saved
        // `profilingEnabled` setting is true. Without this, a user who
        // flipped the toggle in a prior session would launch with the
        // setting persisted as `true` but the profiler dormant — no
        // PROFILE lines until they flip the toggle again.
        await turnProfiler.setEnabled(settings.profilingEnabled)
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
    /// Pull warmup timings from a sidecar's `health` RPC and update
    /// `warmupPhases[name]` accordingly. Called once per sidecar
    /// when its lifecycle transitions to `.ready` so Health renders
    /// real "warm · load Xs + JIT Ys" timings even if the LogBus
    /// log-event channel raced against the pump's subscription
    /// during sidecar startup. Pull-based source of truth.
    fileprivate func refreshWarmupFromHealth(
        name: String, sidecar: any Sidecar
    ) async {
        struct Empty: Encodable, Sendable {}
        struct Health: Decodable, Sendable {
            let loaded: Bool?
            let warm: Bool?
            let load_time_ms: Int?
            let warmup_ms: Int?
            let warmup_failed: String?
        }
        do {
            let h: Health = try await sidecar.send(
                method: "health", params: Empty()
            )
            let next: WarmupPhase
            if let reason = h.warmup_failed {
                next = .failed(reason: reason)
            } else if h.warm == true {
                next = .ready(loadMs: h.load_time_ms, warmMs: h.warmup_ms)
            } else if h.loaded == true {
                next = .warming
            } else {
                // Sidecar reports `loaded: false` but its lifecycle
                // hit `.ready` — that's the historical lazy-load
                // pattern (STT/TTS deferred load to first RPC).
                // Treat as ready-with-unknown-timings rather than
                // perpetually-loading.
                next = .ready(loadMs: h.load_time_ms, warmMs: h.warmup_ms)
            }
            warmupPhases[name] = next
            await logBus.publish(.sidecarLog(
                sidecar: name, level: .info,
                message: "warmup health snapshot",
                fields: [
                    "load_time_ms": h.load_time_ms.map(String.init) ?? "nil",
                    "warmup_ms": h.warmup_ms.map(String.init) ?? "nil",
                    "warm": String(h.warm ?? false),
                ]
            ))
        } catch {
            await logBus.publish(.sidecarLog(
                sidecar: name, level: .warn,
                message: "warmup health fetch failed: \(error)",
                fields: [:]
            ))
        }
    }

    /// Brain-specific shim — keeps the existing call site readable.
    fileprivate func refreshBrainWarmupFromHealth() async {
        guard let brainSidecar else { return }
        await refreshWarmupFromHealth(name: "brain", sidecar: brainSidecar)
    }

    /// Decode a `phase` field from a sidecar log line into a
    /// `WarmupPhase` mutation. Called from the LogBus pump on
    /// `.sidecarLog` events that carry a `phase=` field. Other log
    /// lines are ignored.
    fileprivate func applyWarmupPhase(
        sidecar: String, phase: String,
        loadMs: Int?, warmMs: Int?, reason: String?
    ) {
        let next: WarmupPhase
        switch phase {
        case "load_start":
            next = .loading
        case "load_done":
            // Brain runs warm_up directly after load, so the next
            // state is .warming. mlx-stt also runs warm immediately
            // after its lazy import. Sidecars that don't do an
            // automatic warmup will overwrite this to .ready when
            // their warm_done fires; for ones that never warm, the
            // process never leaves .warming — which is correct
            // because the first inference IS still slow.
            next = .warming
        case "warm_done":
            next = .ready(loadMs: loadMs, warmMs: warmMs)
        case "warm_failed", "load_failed":
            next = .failed(reason: reason ?? phase)
        default:
            return  // unknown phase: leave state unchanged
        }
        warmupPhases[sidecar] = next
    }

    /// When a sidecar's lifecycle transitions, reset/finalize the
    /// warmup phase so the StatusView doesn't show stale data.
    ///   - `.starting`: process just spawned — clear to .idle so a
    ///     restart of a previously-warm sidecar shows fresh warmup
    ///     progress, not a stale "warm · 3.2 s".
    ///   - `.stopped`, `.failing`, `.circuitOpen`: clear too.
    ///   - `.ready`: leave alone — the log-driven path is the
    ///     authoritative source of `warmMs`. For sidecars that
    ///     don't emit phase logs (mlx-tts, mempalace today),
    ///     promote .idle to .ready so the UI shows a useful state
    ///     instead of permanent "idle".
    fileprivate func reconcileWarmupOnStateChange(sidecar: String, state: SidecarState) {
        switch state {
        case .stopped, .starting, .failing, .circuitOpen:
            warmupPhases[sidecar] = .idle
        case .ready:
            if case .idle = warmupPhases[sidecar] ?? .idle {
                warmupPhases[sidecar] = .ready(loadMs: nil, warmMs: nil)
            }
        }
    }

    private func warmUpSTT() async {
        // Apple Speech authorisation: keep this even when WhisperKit
        // is the active engine. Apple Speech is the M0 fallback if
        // WhisperKit fails to load (corrupt cache, ANE saturation,
        // etc.) and the OS-level prompt has to fire either way to
        // keep the Permissions panel honest.
        let initial = SFSpeechRecognizer.authorizationStatus()
        if initial == .notDetermined {
            await MainActor.run { self.sttBackendName = "Apple Speech (pending)" }
        } else {
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

        // STT engine selection ladder. `auto` races Apple Speech +
        // MLX-Whisper so the first non-empty transcript wins (Apple
        // typically lands in ~100 ms on clean speech, MLX rescues the
        // noisy / distant cases that Apple misses). Falls through to
        // WhisperKit, then leaves Apple Speech in place. Explicit
        // engine choices skip the ladder and try only the requested
        // engine.
        let pref = await MainActor.run { self.settings.sttEngine }
        guard pref != "apple" else { return }

        // ---- MLX-Whisper (mlx-stt sidecar), optionally raced with Apple ----
        let tryMLX = (pref == "auto" || pref == "mlx-whisper")
        if tryMLX, let mlxSTTSidecar {
            do {
                try await mlxSTTSidecar.start()
                let mlx = MLXWhisperSTT(sidecar: mlxSTTSidecar)
                // Warm-up runs a 1 s silence transcribe so model
                // weights are loaded before the user's first utterance.
                // Failures here only surface a log line; we still
                // install the engine since the first real call will
                // retry the load.
                do { try await mlx.warmUp() } catch {
                    await logBus.publish(.sidecarLog(
                        sidecar: "voice", level: .warn,
                        message: "MLX-Whisper warm-up failed (non-fatal): \(error)",
                        fields: [:]
                    ))
                }
                // Auto mode + Apple Speech authorized → race them so
                // the user gets Apple's ~100 ms latency on clean
                // speech, with MLX as a fallback for noisy segments.
                // Explicit "mlx-whisper" gets bare MLX.
                let appleReady = await self.appleSTT.status == .ready
                let engine: any STTEngine
                let label: String
                if pref == "auto", appleReady {
                    engine = RacingSTT(
                        fast: self.appleSTT,
                        accurate: mlx,
                        logBus: self.logBus
                    )
                    label = "Race (Apple Speech + MLX-Whisper)"
                } else {
                    engine = mlx
                    label = "MLX-Whisper (small-mlx)"
                }
                await voice.setSTT(engine)
                await MainActor.run {
                    self.sttBackendName = label
                }
                await logBus.publish(.sidecarLog(
                    sidecar: "voice", level: .info,
                    message: "STT engine: \(label)",
                    fields: [:]
                ))
                fputs("[stt] engine = \(label)\n", stderr)
                return
            } catch {
                fputs("[stt] MLX-Whisper start failed: \(error) — falling through\n", stderr)
                await logBus.publish(.error(
                    scope: "voice/stt",
                    message: "MLX-Whisper sidecar failed to start: \(error)",
                    recoverable: true
                ))
            }
        } else if tryMLX {
            // Sidecar nil — venv not installed. Inform the user in
            // auto mode (where the fallback is silent and confusing).
            await logBus.publish(.sidecarLog(
                sidecar: "voice", level: .info,
                message: "MLX-Whisper venv not found — run Sidecars/mlx-stt/setup.sh to enable. Trying WhisperKit.",
                fields: [:]
            ))
        }

        // ---- WhisperKit (CoreML) ----
        guard pref == "auto" || pref == "whisperkit" else { return }
        if let wk = await WhisperKitSTT.tryDefault() {
            await voice.setSTT(wk)
            await MainActor.run {
                self.sttBackendName = "WhisperKit (large-v3-turbo)"
            }
            await logBus.publish(.sidecarLog(
                sidecar: "voice",
                level: .info,
                message: "STT engine: WhisperKit (whisper-large-v3-turbo)",
                fields: [:]
            ))
            fputs("[stt] engine = WhisperKit (CoreML)\n", stderr)
        } else if pref == "whisperkit" {
            await logBus.publish(.error(
                scope: "voice/stt",
                message: "WhisperKit requested but failed to load; falling back to Apple Speech.",
                recoverable: true
            ))
        }
    }

    func stop() async {
        await voice.stop()
        await stateSubscriber.stop()
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
                group.addTask { [motionGuard] in
                    try await motionGuard.goToSleep()
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
            try? await motionGuard.setMotorMode(.disabled)
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
                // Make silent failures observable. Without this the UI
                // shows only a small red caption in CockpitView; if the
                // user is on a different tab, the error vanishes. Both
                // logBus (LogsView) and stderr (Console / terminal)
                // surface the real exception for diagnosis.
                fputs("[mic] toggleMic enable FAILED — source=\(settings.micSource), error=\(error)\n", stderr)
                await logBus.publish(.error(
                    scope: "voice/mic-toggle",
                    message: "enable failed (source=\(settings.micSource)): \(error)",
                    recoverable: true
                ))
            }
        }
    }

    private func handleVoice(_ output: VoiceCoordinator.Output) async {
        switch output {
        case .partial(let text):
            await MainActor.run { self.lastTranscript = text }
        case let .finalText(text, admitted, reason, confidence, peakRMS, _):
            await MainActor.run {
                self.lastTranscript = text
                if admitted { self.lastDispatched = text }
            }
            // Wake-on-name: a fresh wake match while asleep also wakes
            // the body. Without this, saying "Rocky" only opens the
            // conversation window — the brain hears the transcript
            // but the motors stay disabled, so any motion or `wake_up`
            // tool call queues behind a sleeping daemon. Fire-and-
            // forget so the brain can think during the ~3 s wake_up
            // move. Follow-ups inside the open window (`.withinWindow`)
            // intentionally don't trigger this — once awake, stay awake.
            if admitted, case .wakeMatch = reason, isAsleep {
                Task { [weak self] in await self?.wakeRobot() }
            }
            guard admitted, let reason else { return }

            // Snapshot the live signals for the AddressFilter. All
            // reads happen here so the filter actor doesn't reach
            // back into the rest of the app.
            let now = Date()
            let ttsActive = ttsBusyUntil.map { now < $0.addingTimeInterval(1.5) } ?? false
            let doaRad = await robotMic.lastDoaRad
            let doaIsSpeech = await robotMic.lastDoaIsSpeech
            let faceAge: TimeInterval? = lastFaceDetectionAt.map { now.timeIntervalSince($0) }
            let noiseCeiling = settings.addressRMSFloor / max(settings.addressLoudnessRatio, 1e-6)

            let signals = AddressFilter.Signals(
                text: text,
                sttConfidence: confidence,
                segmentPeakRMS: peakRMS,
                segmentMeanRMS: 0,  // unused by current rules; reserved
                roomNoiseCeiling: noiseCeiling,
                doaRad: doaRad,
                doaIsSpeech: doaIsSpeech,
                faceVisibleAgeS: faceAge,
                wakeReason: reason,
                ttsActive: ttsActive,
                micSource: settings.micSource
            )
            let decision = await addressFilter.decide(signals)

            switch decision {
            case .dispatch(let score, let reasons, let engaged):
                await logBus.publish(.addressFilterAccept(
                    text: text, score: score, reasons: reasons
                ))
                if engaged {
                    // Real engagement — extend the conversation
                    // window so the user can keep going without
                    // saying "Rocky" every turn.
                    await wakeFilter.extendOnEngaged()
                    if case .open(let until) = await wakeFilter.state {
                        await MainActor.run { self.conversationOpenUntil = until }
                        await logBus.publish(.conversationWindow(
                            transition: .extended, reason: "engaged"
                        ))
                    }
                }
                await sendUserText(text)
            case .drop(let score, let reasons):
                await logBus.publish(.addressFilterDrop(
                    text: text, score: score, reasons: reasons
                ))
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

    /// Hot-apply a freshly-calibrated AddressFilter config. Used by
    /// `MicCalibrationView` after the user re-runs the calibration
    /// flow so the new thresholds take effect without an app relaunch.
    /// Also writes through to `SettingsStore` so they survive relaunch.
    func applyAddressFilterCalibration(
        rmsFloor: Double,
        loudnessRatio: Double,
        userDoaCenterRad: Double,
        userDoaToleranceRad: Double
    ) async {
        await MainActor.run {
            self.settings.addressRMSFloor = rmsFloor
            self.settings.addressLoudnessRatio = loudnessRatio
            self.settings.addressUserDoaCenterRad = userDoaCenterRad
            self.settings.addressUserDoaToleranceRad = userDoaToleranceRad
        }
        var cfg = await addressFilter.currentConfig()
        cfg.rmsFloor = rmsFloor
        cfg.loudnessRatio = loudnessRatio
        cfg.userDoaCenterRad = userDoaCenterRad
        cfg.userDoaToleranceRad = userDoaToleranceRad
        await addressFilter.setConfig(cfg)
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

        // Check the *active* brain backend rather than always
        // probing LM Studio. When the user has picked MLX-VLM (or
        // "auto" with the sidecar running), LM Studio being down
        // is fine — the brain doesn't go through it.
        if let offline = await brainOfflineMessage() {
            await MainActor.run {
                self.brainTurns.append(.init(role: "user", content: trimmed))
                self.brainTurns.append(.init(role: "assistant", content: offline))
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
                // Buffer the `say` tool's text argument captured at
                // dispatch time so we can render it as the assistant
                // bubble when the result returns.
                var pendingSayText: String? = nil
                let started = Date()
                // Track whether we've already pushed a `.brainResponse`
                // to LogBus for this drain. `assistantFinal` only fires
                // in the no-tool-calls exit branch — for turns that
                // emit tool calls (the common case), we have to
                // publish ourselves at end-of-stream so the profiler
                // sees brain timing.
                var brainResponsePublished = false
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
                        case .assistantFinal(let finalText, let totalMs, let firstMs):
                            // The engine's final text is authoritative
                            // — already through tool-call recovery,
                            // thought-marker stripping, and TTS
                            // cleanup. If it differs from the raw
                            // delta buffer, REPLACE the bubble's
                            // content with the clean version.
                            //
                            // Empty `finalText` is a deliberate signal
                            // that the engine wants the bubble REMOVED
                            // (e.g. duplicate-bubble suppression: a
                            // round with a `say` tool call will
                            // produce its canonical bubble on tool
                            // success, so the streamed brain content
                            // bubble must go away). Drop the entry
                            // entirely rather than leaving an empty
                            // container in the chat.
                            let id = assistantTurnId
                            let displayText = finalText
                            assistantBuffer = displayText
                            await MainActor.run { [weak self] in
                                guard let self else { return }
                                if displayText.isEmpty {
                                    if let id,
                                       let idx = self.brainTurns.firstIndex(where: { $0.id == id })
                                    {
                                        self.brainTurns.remove(at: idx)
                                    }
                                    return
                                }
                                if let id, let idx = self.brainTurns.firstIndex(where: { $0.id == id }) {
                                    self.brainTurns[idx].content = displayText
                                    self.brainTurns[idx].totalMs = totalMs
                                    self.brainTurns[idx].firstChunkMs = firstMs
                                } else {
                                    var t = BrainTurn(role: "assistant", content: displayText)
                                    t.totalMs = totalMs
                                    t.firstChunkMs = firstMs
                                    self.brainTurns.append(t)
                                }
                            }
                            // Reset the turn id so the next round starts
                            // a fresh bubble instead of trying to
                            // update the one we just removed.
                            if displayText.isEmpty { assistantTurnId = nil }
                            // Mirror brain timings onto LogBus so the
                            // TurnProfiler (and anything else subscribing)
                            // can attribute brain TFT + total without
                            // having to consume the cognition stream.
                            await self.logBus.publish(.brainResponse(
                                firstChunkMs: firstMs,
                                totalMs: totalMs
                            ))
                            brainResponsePublished = true
                        case .toolCallDispatched(let name, let argumentsJSON, _):
                            // Tool dispatch is also a valid "first
                            // chunk" signal — many models emit tool
                            // calls without any content text, in which
                            // case `assistantDelta` never fires.
                            if firstChunkMs == nil {
                                firstChunkMs = Date().timeIntervalSince(started) * 1000
                            }
                            let detail = argumentsJSON
                            // Stash the say text so we can mirror it into
                            // an assistant bubble after the tool returns;
                            // the chat then matches the audio rather than
                            // showing whatever the model chatters next.
                            if name == "say" {
                                pendingSayText = Self.extractSayText(
                                    from: argumentsJSON
                                )
                            }
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
                            let sayText: String? = {
                                guard name == "say", result.ok else { return nil }
                                let t = pendingSayText
                                pendingSayText = nil
                                return t
                            }()
                            let sayMirrored = (sayText != nil && !(sayText ?? "").isEmpty)
                            await MainActor.run { [weak self] in
                                guard let self else { return }
                                self.brainTurns.append(.init(
                                    role: "tool",
                                    content: "← \(name) (\(summary), \(Int(ms))ms)",
                                    detail: detail
                                ))
                                if let sayText, !sayText.isEmpty {
                                    // Preamble-bubble suppression. The
                                    // model often emits the same answer
                                    // text as `content` in an EARLIER
                                    // round (e.g. round 1 with a data
                                    // tool like recall_memory) AND as
                                    // the `say` text in a later round —
                                    // producing two identical chat
                                    // bubbles. The same-round
                                    // speech-detection in
                                    // CognitionEngine catches the
                                    // within-round case; this handles
                                    // the across-round case by walking
                                    // back to the most recent user
                                    // message and stripping every
                                    // assistant-role entry between it
                                    // and the say. Tool rows survive
                                    // (the user wants to see what tools
                                    // ran).
                                    if let lastUserIdx = self.brainTurns.lastIndex(
                                        where: { $0.role == "user" }
                                    ) {
                                        var i = self.brainTurns.count - 1
                                        while i > lastUserIdx {
                                            if self.brainTurns[i].role == "assistant" {
                                                self.brainTurns.remove(at: i)
                                            }
                                            i -= 1
                                        }
                                    }
                                    self.brainTurns.append(.init(
                                        role: "assistant", content: sayText
                                    ))
                                }
                            }
                            // Reset the streamed-bubble cursor in the
                            // outer scope since the bubble it pointed
                            // at may have just been removed.
                            if sayMirrored {
                                assistantTurnId = nil
                                assistantBuffer = ""
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
                // Catch-all brain timing publish. The `assistantFinal`
                // exit branch already pushes `.brainResponse` — but
                // tool-using turns (the common case: say+search_web+
                // say) never reach that branch, they return after the
                // final say lands. Without this, profiler brain
                // columns are always empty for the interesting turns.
                if !brainResponsePublished, let self {
                    let totalMs = Date().timeIntervalSince(started) * 1000
                    await self.logBus.publish(.brainResponse(
                        firstChunkMs: firstChunkMs,
                        totalMs: totalMs
                    ))
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
        // Route through MotionGuard — slew + velocity + duration
        // floor guards apply to every step of the expression.
        let robot = motionGuard
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
            // Reset the TargetStreamer's `latest` to neutral so the
            // streamer doesn't resume by pushing the stale face-
            // tracking target it held BEFORE the expression began
            // (the suppression during transition prevented the
            // face tracker from updating it). Without this, the
            // head settles to wherever the streamer's stale target
            // points — observed as "stuck looking down" after a
            // curious gesture finishes. With this, the head returns
            // to neutral, and the face tracker takes over normally
            // on its next tick if a face is in view.
            // Antenna rest pose is ±0.1745 rad (10°) — they shake
            // mechanically at 0, so the safe rest is the off-vertical
            // pair the Pollen firmware ships with.
            let neutralTarget = MotionTarget(
                headPose: neutral,
                antennas: Antennas(rightRad: -0.1745, leftRad: 0.1745),
                bodyYaw: 0
            )
            Task { [weak self] in
                await self?.targetStreamer.update(neutralTarget, source: .tool)
            }
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
        await macFaceTracker.setEnabled(false)
        defer { Task { await macFaceTracker.setEnabled(true) } }

        // Route through MotionGuard so the shelf-safe allowlist gates
        // dangerous moves (dance, rage, etc.) by default. Force=true
        // is reserved for an explicit user opt-in path (not wired yet).
        try await motionGuard.playRecordedMove(dataset: dataset, move: name)

        // Velocity watchdog + completion / cap loop. Sample the
        // mirrored state every 50 ms (≈20 Hz) and:
        //   - return early when the daemon reports no move running
        //   - force-stop on excessive instantaneous joint velocity
        //   - force-stop on cap timeout
        // All motion-affecting calls in the watchdog route through
        // MotionGuard. The previous version used `self.robotLink`
        // directly which bypassed the chokepoint — per the rule:
        // EVERY motion command MUST go through `motionGuard`. The
        // only direct-robotLink calls allowed here are READ-ONLY
        // queries (e.g. `isMoveRunning()`), which MotionGuard
        // doesn't bother wrapping.
        let logBus = self.logBus
        let guardian = self.motionGuard
        let raw = self.robotLink  // read-only queries only
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
                    try? await guardian.stopMove()
                    await logBus.publish(.error(
                        scope: "play_emotion.watchdog",
                        message: "aborted \(name): joint velocity \(String(format: "%.2f", v)) rad/s exceeded ceiling \(SafetyLimits.maxJointVelocityRadPerS)",
                        recoverable: true))
                    return
                }
            }
            prevPose = pose
            prevTime = now
            if let running = try? await raw.isMoveRunning(), !running {
                return
            }
        }
        try? await guardian.stopMove()
    }

    /// Stop face tracking from pushing target events into the streamer.
    /// Mirrored on `faceTrackingEnabled` so the menu bar and main
    /// window stay in lockstep regardless of which surface toggled it.
    func setFaceTrackingEnabled(_ enabled: Bool) async {
        faceTrackingEnabled = enabled
        await macFaceTracker.setEnabled(enabled)
    }

    /// Toggle whether camera frames are passed to the brain on each
    /// chat turn. Idempotent. Does NOT stop the camera sidecar —
    /// the Vision card and face tracker still operate.
    func setVisionEnabled(_ enabled: Bool) {
        visionEnabled = enabled
    }

    /// Tracks the last successful auto-wake so we don't spam the daemon.
    private var lastAutoWakeAt: Date?

    /// Watches mic RMS for a loud transient while sleeping, and wakes
    /// the robot when one fires. Single-tap detection: any RMS above
    /// Parse the `text` argument out of a `say` tool's JSON arguments.
    /// Returns `nil` when the JSON is malformed or `text` is absent —
    /// the caller treats that as "no spoken text to mirror," so the
    /// chat bubble stays untouched.
    nonisolated private static func extractSayText(from argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return nil }
        guard let text = obj["text"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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
            let (asleep, micOn, useRobot, enabled) = await MainActor.run {
                (self.isAsleep,
                 self.micEnabled,
                 self.settings.micSource == "robot",
                 self.settings.wakeOnPat)
            }
            guard enabled, asleep, micOn else { continue }
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
        // wakeUp pre-seeds set_target to the current physical pose,
        // enables motors (at-rest, no snap), and runs a single ~2 s
        // minjerk goto to neutral. transitioningUntil suppresses the
        // face-tracker streamer (and TargetStreamer.setPrimaryMoveActive)
        // for the full window so the goto isn't fought by streaming
        // updates.
        await MainActor.run {
            self.transitioningUntil = Date().addingTimeInterval(3.2)
        }
        // Tell the face tracker we're awake so it resumes frame
        // ingestion + (optional) idle search.
        await macFaceTracker.setSleeping(false)
        // Bring the camera feed back up *before* the wake motion so
        // the first frames arrive while Rocky is opening his eyes.
        // Mic stays on while sleeping (wake-on-name), so no mic call.
        Task { [robotCamera, logBus] in
            do { try await robotCamera.resumeStreaming() }
            catch {
                await logBus.publish(.error(
                    scope: "robot-camera",
                    message: "resume failed: \(error)",
                    recoverable: true
                ))
            }
        }
        do {
            try await motionGuard.wakeUp()
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
            // Conversation window stays open across normal idle gaps,
            // but when the user explicitly sleeps Rocky we close it so
            // that subsequent audio is gated by the wake filter again.
            // Without this, any sound (or the bot's own goodbye TTS
            // bleed) is auto-dispatched to the brain — which can
            // tool-call `wake_up` and re-wake the bot the user just
            // put to sleep.
            self.conversationOpenUntil = nil
        }
        await voice.closeConversationWindow()
        // Tell the face tracker we're asleep so it stops processing
        // camera frames (no point — motors are off). This also
        // disables the idle look-around if it was enabled.
        await macFaceTracker.setSleeping(true)
        do { try await motionGuard.goToSleep() }
        catch {
            await MainActor.run { self.transitioningUntil = nil }
            await logBus.publish(.error(
                scope: "app/sleep", message: "\(error)", recoverable: true
            ))
        }
        // Camera feed sleeps with the robot. Mic stays on so the
        // user can still say "Rocky" to wake him. The relay only
        // encodes JPEGs when it has a /ws/video client connected,
        // so closing our subscription also stops bot-side encoding.
        await robotCamera.pauseStreaming()
    }

    /// Ensure the on-bot `rocky_media_relay` Reachy Mini App is the
    /// currently-running app on the bot. The daemon doesn't restore
    /// the last running app across reboots, so after every
    /// power-cycle the bot comes up with `current-app-status: null`
    /// and our WebSocket subscribers have nothing to talk to. This
    /// task closes that gap from the Mac side without needing a
    /// systemd unit on the bot.
    ///
    /// Behaviour:
    ///   1. Wait (with backoff) until the daemon's HTTP endpoint
    ///      responds.
    ///   2. Probe `/api/apps/current-app-status`.
    ///   3. If the relay is already running → done.
    ///   4. If a *different* app is running → leave it alone (the
    ///      user picked it). Log a hint so the user knows Rocky
    ///      won't have audio/video until the relay is the active
    ///      app.
    ///   5. If nothing is running → POST
    ///      `/api/apps/start-app/rocky_media_relay`.
    ///
    /// Fire-and-forget from `start()`. Runs once per app launch.
    private func ensureRelayAppRunning() async {
        let host = settings.robotHost
        let daemonPort = settings.robotPort
        let base = "http://\(host):\(daemonPort)"
        let relayName = "rocky_media_relay"

        struct StatusInfo: Decodable {
            let name: String?
        }
        struct StatusResponse: Decodable {
            let info: StatusInfo?
            let state: String?
        }

        // 1. Wait for daemon to be reachable. Probe at ~3s intervals
        // for up to ~3 minutes; that covers a bot mid-boot. If it's
        // genuinely offline beyond that, leave it — the user will
        // notice and the WS subscriber's reconnect loop will pick
        // it up when the bot eventually appears.
        let session = URLSession.shared
        let statusURL = URL(string: "\(base)/api/apps/current-app-status")!
        let startURL = URL(string: "\(base)/api/apps/start-app/\(relayName)")!
        let probeBudget: Int = 60   // 60 × ~3s = 3 min
        var reachable = false
        for _ in 0..<probeBudget {
            do {
                let (_, resp) = try await session.data(for: URLRequest(url: statusURL))
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    reachable = true
                    break
                }
            } catch {
                // not reachable yet; keep waiting
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        guard reachable else {
            fputs("[relay] daemon never came online; skipping auto-start\n", stderr)
            return
        }

        // 2. Probe current app status.
        let currentName: String?
        do {
            let (data, _) = try await session.data(for: URLRequest(url: statusURL))
            if data.isEmpty || data == Data("null".utf8) {
                currentName = nil
            } else if let decoded = try? JSONDecoder().decode(StatusResponse.self, from: data) {
                currentName = decoded.info?.name
            } else {
                currentName = nil
            }
        } catch {
            fputs("[relay] status probe failed: \(error)\n", stderr)
            return
        }

        // 3 / 4. Decide what to do.
        if currentName == relayName {
            fputs("[relay] \(relayName) already running on bot\n", stderr)
            return
        }
        if let other = currentName, !other.isEmpty {
            fputs(
                "[relay] another app is running on the bot (\(other)). "
                + "Rocky's audio/video won't flow until that app is "
                + "stopped and \(relayName) is started.\n", stderr)
            await logBus.publish(.error(
                scope: "relay",
                message: "bot running '\(other)' — Rocky needs '\(relayName)' for audio + video",
                recoverable: true
            ))
            return
        }

        // 5. Nothing running — start the relay.
        var req = URLRequest(url: startURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                fputs("[relay] started \(relayName) on bot\n", stderr)
                await logBus.publish(.sidecarLog(
                    sidecar: "relay", level: .info,
                    message: "auto-started \(relayName) on bot after reboot",
                    fields: [:]
                ))
            } else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                fputs("[relay] start-app returned HTTP \(code)\n", stderr)
            }
        } catch {
            fputs("[relay] start-app request failed: \(error)\n", stderr)
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
        await turnProfiler.setEnabled(settings.profilingEnabled)
        await probeLMStudio()
    }

    /// Apply the user's `settings.brainBackend` choice. Hot-swaps
    /// CognitionEngine's active brain without requiring a relaunch.
    /// Three paths:
    ///   - "lm-studio": stop the brain sidecar (if running), wire
    ///     LMStudioBrain, drop the image provider.
    ///   - "mlx-vlm": start the brain sidecar (if not yet started),
    ///     wire MLXVLMBrain + camera-frame provider. If the sidecar
    ///     isn't installed, log a warning and fall back to LM Studio.
    ///   - "auto" (default): same as "mlx-vlm" when the sidecar is
    ///     installed, else LM Studio. Silent fallback (no warning).
    /// Also called once at app start; idempotent.
    func applyBrainBackend() async {
        let pref = settings.brainBackend
        let wantsMLX = (pref == "auto" || pref == "mlx-vlm")
        fputs("[brain] applyBrainBackend: pref=\(pref) wantsMLX=\(wantsMLX) sidecar=\(brainSidecar == nil ? "nil" : "present")\n", stderr)
        // Force LM Studio path: clean up the sidecar if running,
        // wire the HTTP backend, drop the camera-frame provider.
        if !wantsMLX {
            if let brainSidecar {
                await brainSidecar.stop()
            }
            await cognition.setBrain(LMStudioBrain(client: llm))
            await cognition.setImageProvider(nil)
            await logBus.publish(.sidecarLog(
                sidecar: "brain",
                level: .info,
                message: "Brain backend: LM Studio (HTTP)",
                fields: [:]
            ))
            return
        }
        // MLX-VLM path: ensure the sidecar is running (start may
        // be a no-op if already running) and route through it.
        guard let brainSidecar else {
            // No sidecar built — venv not installed. Behaviour
            // depends on whether the user explicitly asked for
            // mlx-vlm or just "auto".
            await cognition.setBrain(LMStudioBrain(client: llm))
            await cognition.setImageProvider(nil)
            if pref == "mlx-vlm" {
                await logBus.publish(.error(
                    scope: "app/brain",
                    message: "MLX-VLM requested but `Sidecars/brain/` venv missing — run `Sidecars/brain/setup.sh` and re-apply. Falling back to LM Studio.",
                    recoverable: true
                ))
            } else {
                await logBus.publish(.sidecarLog(
                    sidecar: "brain", level: .info,
                    message: "Brain backend: LM Studio (HTTP) — brain venv not installed",
                    fields: [:]
                ))
            }
            return
        }
        // start() throws SidecarError.alreadyRunning if the sidecar
        // is already in .ready or .starting state — that's not a
        // failure, just "already up." Suppress it; any other error
        // is real and demotes us to LMStudioBrain.
        do {
            fputs("[brain] applyBrainBackend: brainSidecar.start() begin\n", stderr)
            try await brainSidecar.start()
            fputs("[brain] applyBrainBackend: brainSidecar.start() OK\n", stderr)
        } catch SidecarError.alreadyRunning {
            // Expected on re-apply (e.g. user changed model in
            // Settings — the sidecar is still running from boot).
            fputs("[brain] applyBrainBackend: alreadyRunning (continuing)\n", stderr)
        } catch {
            fputs("[brain] applyBrainBackend: start() ERROR \(error) — falling back to LM Studio\n", stderr)
            await cognition.setBrain(LMStudioBrain(client: llm))
            await cognition.setImageProvider(nil)
            if pref == "mlx-vlm" {
                await logBus.publish(.error(
                    scope: "app/brain",
                    message: "MLX-VLM start failed: \(error). Falling back to LM Studio.",
                    recoverable: true
                ))
            }
            return
        }
        // If the user changed `brainModel` since the last apply,
        // the sidecar's loaded model still matches whatever env it
        // spawned with. Send `set_model` to hot-swap. No-op when the
        // requested model is already loaded.
        await self.requestBrainModel(settings.brainModel)
        let mlx = MLXVLMBrain(sidecar: brainSidecar, logBus: logBus)
        await cognition.setBrain(mlx)
        fputs("[brain] applyBrainBackend: cognition.brain = MLXVLMBrain (\(settings.brainModel))\n", stderr)
        // Wire the latest camera frame so the VLM has eyes. Gated by
        // `visionEnabled` so the user can blind the model from the
        // toolbar without stopping the camera sidecar.
        let provider: CognitionEngine.ImageProvider = { [weak self] in
            guard let self else { return nil }
            let (frame, enabled) = await MainActor.run {
                (self.lastCameraFrame, self.visionEnabled)
            }
            guard enabled else { return nil }
            return frame.map { BrainImage(jpegData: $0.jpeg) }
        }
        await cognition.setImageProvider(provider)
        await logBus.publish(.sidecarLog(
            sidecar: "brain", level: .info,
            message: "Brain backend: MLX-VLM (\(settings.brainModel))",
            fields: [:]
        ))
    }

    /// Returns nil if the active brain backend is online and ready
    /// to take a turn. Otherwise returns a user-facing string
    /// describing what's wrong and how to fix it — backend-aware:
    /// "start LM Studio" only when LM Studio is actually the active
    /// backend, not when MLX-VLM is in charge.
    func brainOfflineMessage() async -> String? {
        switch settings.brainBackend {
        case "lm-studio":
            if case .unknown = llmStatus { await probeLMStudio() }
            if case .offline(let reason) = llmStatus {
                return "(brain offline · \(reason)) — start LM Studio to talk to Rocky."
            }
            return nil
        case "mlx-vlm":
            if brainSidecar == nil {
                return "(brain offline) — MLX-VLM selected but `Sidecars/brain/` venv not installed. Run `./Sidecars/brain/setup.sh` and choose Settings → Brain → Restart brain."
            }
            switch brainSidecarState {
            case .ready: return nil
            case .starting:
                return "(brain warming up) — MLX-VLM is loading the model. First run downloads ~2.5 GB of weights; subsequent launches are fast."
            case .stopped:
                return "(brain offline) — MLX-VLM sidecar not running. Open Settings → Brain and tap Restart brain."
            case .failing(let r):
                return "(brain failing · \(r)) — MLX-VLM sidecar in restart loop. Check the logs."
            case .circuitOpen(let until):
                let fmt = until.formatted(.dateTime.hour().minute().second())
                return "(brain backing off until \(fmt)) — MLX-VLM has hit its restart cap; waiting before re-trying."
            }
        default: // "auto"
            // Pick whichever backend is alive. Prefer MLX-VLM if the
            // sidecar's ready; fall back to LM Studio when it's not.
            if brainSidecar != nil, brainSidecarState == .ready {
                return nil
            }
            // Brain sidecar not (yet) ready — see if LM Studio is.
            if case .unknown = llmStatus { await probeLMStudio() }
            if case .online = llmStatus { return nil }
            // Neither available — describe both states briefly.
            var parts: [String] = []
            if let brainSidecar {
                _ = brainSidecar
                parts.append(brainStateHumanReadable())
            } else {
                parts.append("MLX-VLM venv not installed")
            }
            if case .offline(let r) = llmStatus {
                parts.append("LM Studio: \(r)")
            }
            return "(brain offline · \(parts.joined(separator: " · "))) — install/start either backend and choose Settings → Brain → Restart brain."
        }
    }

    private func brainStateHumanReadable() -> String {
        switch brainSidecarState {
        case .ready:    return "MLX-VLM ready"
        case .starting: return "MLX-VLM warming up"
        case .stopped:  return "MLX-VLM stopped"
        case .failing(let r): return "MLX-VLM failing (\(r))"
        case .circuitOpen: return "MLX-VLM in backoff"
        }
    }

    /// Hot-swap the brain sidecar's loaded MLX model. Best-effort —
    /// if the sidecar isn't running or the request fails, the prior
    /// model stays loaded.
    func requestBrainModel(_ name: String) async {
        guard let brainSidecar else { return }
        struct Params: Encodable, Sendable { let name: String }
        struct Result: Decodable, Sendable { let model: String? }
        do {
            let _: Result = try await brainSidecar.send(
                method: "set_model", params: Params(name: name)
            )
        } catch {
            await logBus.publish(.error(
                scope: "app/brain",
                message: "set_model(\(name)) failed: \(error)",
                recoverable: true
            ))
        }
    }

    // MARK: - Tools

    private func registerInitialTools() async {
        // Every motion command from a registered tool routes through
        // MotionGuard — that's the chokepoint for slew, velocity,
        // duration-floor, single-in-flight, and shelf-safety guards.
        // Direct `robotLink.*` motion calls in tool handlers are
        // forbidden (they bypass safety).
        let robot = motionGuard
        let bus = logBus

        // Image-grounded variant — call this when the user asks to
        // look at something visible in the current camera frame
        // ("look at the cup", "look over there at the book"). The
        // brain locates the target in the frame it sees and passes
        // normalised image coordinates; the tool handles FOV math.
        await LookAtTool.register(in: toolRegistry, services: self)

        await toolRegistry.register(
            name: "look_at",
            description: "Make Rocky orient his head toward a yaw/pitch in degrees. Yaw: -180..180 (positive = left). Pitch: -40..40 (positive = down). The default duration_s is deliberately slow (1.2s) for a calm, deliberate look — only specify shorter durations if the user explicitly asks for a quick glance. Use this when you have a specific angle in mind; if the user asks to look at something visible in the current camera frame, prefer `look_at_object` so you don't have to estimate the FOV yourself.",
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

        // `go_home` — full reset to neutral. Distinct from `wakeUp`,
        // which only handles the motor-enable + head-identity goto
        // and leaves body / antennas wherever they were. `go_home`
        // commands EVERY joint:
        //
        //   head pose  → (roll: 0, pitch: 0, yaw: 0)
        //   body yaw   → 0
        //   antennas   → (right: -0.1745, left: +0.1745) rad — the
        //                Pollen-documented rest offset (10° off
        //                vertical) so antennas don't shake.
        //
        // Everything else (motor enable, streamer reset, face-tracker
        // pause/resume, motion-guard routing) applies as before. 2 s
        // minjerk goto, all four joint groups arriving together.
        let faceTrackerForHome = macFaceTracker
        let streamerForHome = targetStreamer
        await toolRegistry.register(
            name: "go_home",
            description: "Reset Rocky to the home pose — head looking straight forward (roll, pitch, yaw = 0), body yaw recentred to 0, antennas at their rest position. Slow, calm 2-second move. This is a STATIC reset to neutral; it does NOT make Rocky look at anyone or anything afterwards. Use ONLY when the user explicitly asks to reset/recentre/go home: 'go home', 'home position', 'rest position', 'reset', 'centre', 'recentre', 'reset pose', 'neutral pose'. For 'look at me' / 'come back' / 'follow me' use `resume_face_tracking` instead (that's the live-tracking command, not a static reset).",
            handler: { [weak self] _ in
                guard let self else {
                    return .object(["ok": .bool(false),
                                    "error": .string("services unavailable")])
                }
                let home = RPYPose(roll: 0, pitch: 0, yaw: 0)
                // Antenna rest position — ±10° off vertical. At
                // exactly 0 rad the antennas mechanically shake
                // (Pollen's INIT_ANTENNAS_JOINT_POSITIONS comment).
                let restAntennas = Antennas(
                    rightRad: -0.1745, leftRad: 0.1745
                )
                let homeTarget = MotionTarget(
                    headPose: home,
                    antennas: restAntennas,
                    bodyYaw: 0
                )
                // Pause face tracker + overwrite streamer.latest BEFORE
                // the goto. Without the second step, the streamer would
                // immediately re-send the previous target (e.g. a
                // look_at_object pose) after the goto completed, and
                // the head would twitch back.
                await faceTrackerForHome.setEnabled(false)
                await streamerForHome.update(homeTarget, source: .tool)
                defer { Task { await faceTrackerForHome.setEnabled(true) } }
                // Defensive: if motors are disabled / compliant
                // (after a goToSleep, or after a hardware fault),
                // commanding goto has no physical effect and the
                // head sags forward under gravity. Read the current
                // mode through the state mirror and enable motors
                // first if needed. Always through motionGuard.
                let currentMode = await MainActor.run { () -> MotorMode? in
                    return self.lastRobotState?.controlMode
                }
                if let mode = currentMode, mode != .enabled {
                    try? await robot.setMotorMode(.enabled)
                    // Tiny settle so the motor-enable physical
                    // transition lands before we issue the goto.
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                try await robot.goto(
                    headPose: home,
                    antennas: restAntennas,
                    bodyYaw: 0,
                    durationS: 2.0,
                    interpolation: .minjerk
                )
                return .object([
                    "ok": .bool(true),
                    "head_pose": .object([
                        "roll": .number(0), "pitch": .number(0), "yaw": .number(0),
                    ]),
                    "body_yaw": .number(0),
                    "antennas": .object([
                        "right": .number(-0.1745), "left": .number(0.1745),
                    ]),
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

        // `wake_up` tool intentionally NOT registered. Waking is a
        // user-only action — either pressing the wake button or
        // saying the wake word ("Rocky") via the wake-on-name path
        // in handleVoice. The brain has no use case for waking the
        // robot itself, and exposing the tool created an auto-wake
        // path where any in-flight brain turn could re-wake the bot
        // moments after the user explicitly put it to sleep.

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
            the same time. Use ONLY when the user explicitly asks Rocky to \
            perform / act / show / dance / play a specific emotion. NEVER \
            invoke `play_emotion` reactively on news, search results, or \
            any answer — the recorded moves are designed for a stable \
            floor mount and can destabilise Rocky on a desk shelf. For \
            reactive emotional underlines during normal conversation, use \
            `express` (head-only, gentle) instead. The `text` Rocky speaks \
            must follow Rocky's voice rules (telegraphic, third person, \
            no -ing/-ed) and fit the emotion.
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
                guard let self else {
                    return .object(["ok": .bool(false),
                                    "error": .string("services unavailable")])
                }
                let obj = args.asObject ?? [:]
                let name = obj["name"]?.asString
                let text = obj["text"]?.asString
                if text == nil || text!.isEmpty {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("missing required `text` (what Rocky says)"),
                    ])
                }
                guard let name else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("missing required `name`"),
                        "valid_names": .array(emotions.map { .string($0) }),
                    ])
                }
                if !emotions.contains(name) {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("unknown emotion `\(name)`"),
                        "valid_names": .array(emotions.map { .string($0) }),
                        "hint": .string(
                            "If you wanted a quick silent gesture, use `express` "
                            + "(scared / agree / disagree / excited / sad / "
                            + "curious / look_around / shy)."
                        ),
                    ])
                }
                try await self.speakAndMove(text: text!) {
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
            and fit the expression. The expression MUST match the meaning \
            of the text — agree with agreement, sad with sad news, curious \
            with a question, etc. Mismatched expressions (e.g. happy gesture \
            on bad news) are forbidden. Each gesture takes 1.5–3 s. \
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
                guard let self else {
                    return .object(["ok": .bool(false),
                                    "error": .string("services unavailable")])
                }
                let obj = args.asObject ?? [:]
                let name = obj["name"]?.asString
                let text = obj["text"]?.asString
                if text == nil || text!.isEmpty {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("missing required `text` (what Rocky says)"),
                    ])
                }
                guard let name else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("missing required `name`"),
                        "valid_names": .array(exprNames.map { .string($0) }),
                    ])
                }
                if !exprNames.contains(name) {
                    // Detect the most common confusion: the model
                    // picked an emotion from `play_emotion`'s richer
                    // catalogue. Route it explicitly so the model
                    // can re-issue against the right tool.
                    let hint: JSONValue
                    if emotions.contains(name) {
                        hint = .string(
                            "`\(name)` is from the `play_emotion` library, "
                            + "not `express`. Re-issue as `play_emotion(name: "
                            + "\"\(name)\", text: ...)` for the full-body "
                            + "recorded move with audio."
                        )
                    } else {
                        hint = .string(
                            "Valid `express` names are head-only silent "
                            + "gestures; check the list and pick the closest, "
                            + "or use `play_emotion` for the larger "
                            + "library that includes sound."
                        )
                    }
                    return .object([
                        "ok": .bool(false),
                        "error": .string("unknown expression `\(name)`"),
                        "valid_names": .array(exprNames.map { .string($0) }),
                        "hint": hint,
                    ])
                }
                try await self.speakAndMove(text: text!) {
                    try await self.playExpression(name)
                }
                return .object(["ok": .bool(true), "name": .string(name)])
            }
        )

        let visionService = macFaceTracker
        await toolRegistry.register(
            name: "pause_face_tracking",
            description: "Stop pushing face-tracking targets to the head. Use before a recorded emotion so the streamer doesn't fight the primary animation.",
            handler: { _ in
                await visionService.setEnabled(false)
                return .object(["ok": .bool(true)])
            }
        )
        // Capture refs the resume handler needs.
        let resumeMotionGuard = motionGuard
        let resumeStreamer = targetStreamer
        await toolRegistry.register(
            name: "resume_face_tracking",
            description: "Resume live face-tracking — Rocky's head + body actively follow the user's face. This is the LIVE-TRACKING command (continuous, dynamic): Rocky FIRST recentres so the camera can see you, then locks onto your face and smoothly turns to keep you in view as you move. Use whenever the user asks Rocky to re-engage with them visually: 'look at me', 'come back', 'follow me', 'watch me', 'look this way', 'engage', 'eyes on me'.",
            handler: { _ in
                // Step 1: recentre. After a look_at_object the
                // streamer's `latest` holds the off-axis target
                // (e.g. the whiteboard on the right wall) and the
                // physical pose points there. If we just toggled
                // the face tracker on, the tracker's first frame
                // wouldn't contain the user's face — so it would
                // never find anyone to track and the bot would stay
                // stuck off-axis. We must physically reset to
                // neutral FIRST so the camera is pointing toward
                // where the user is likely to be, THEN enable
                // tracking and let it lock on.
                let home = RPYPose(roll: 0, pitch: 0, yaw: 0)
                let restAntennas = Antennas(rightRad: -0.1745, leftRad: 0.1745)
                let homeTarget = MotionTarget(
                    headPose: home, antennas: restAntennas, bodyYaw: 0
                )
                // Stamp the streamer's latest with neutral so it
                // doesn't keep re-pushing the stale look_at target
                // the moment the goto finishes.
                await resumeStreamer.update(homeTarget, source: .tool)
                // Routed through MotionGuard. Faster than go_home's
                // 2.0 s because "look at me" should feel responsive
                // — 1.0 s minjerk reads as a deliberate
                // turn-toward-the-user without feeling abrupt.
                try await resumeMotionGuard.goto(
                    headPose: home,
                    antennas: restAntennas,
                    bodyYaw: 0,
                    durationS: 1.0,
                    interpolation: .minjerk
                )
                // Now enable tracking. The first camera frame after
                // this should contain the user (since Rocky is now
                // forward-facing), the tracker finds the face, and
                // streamer's `latest` immediately picks up the new
                // face-tracking target.
                await visionService.setEnabled(true)
                return .object([
                    "ok": .bool(true),
                    "recentred": .bool(true),
                    "next_step": .string("Face tracker is live. Describe what you see of the user."),
                ])
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
                // Single-shot synth → upload → play_sound. `speak()`
                // returns as soon as `play_sound` is dispatched (audio
                // is now playing on the robot); it does NOT wait for
                // audio to finish. The brain unblocks immediately and
                // can think about the next user turn while Rocky is
                // still talking. The echo gate (`isSpeaking` flag
                // mirrored into `ttsBusyUntil` via
                // `streamingTTS.isSpeakingStream`) stays engaged for
                // `durationS + sttPostRollS` so STT doesn't pick up
                // Rocky's own voice.
                let stats = try await tts.speak(text)
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
        await RecallMemoryTool.register(in: toolRegistry, memory: memory)
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

    /// VAD factory: resolves `settings.vadEngine` to a concrete
    /// implementation. Posts a `LogBus` warning if Silero was
    /// requested but the CoreML model isn't installed; falls back
    /// to EnergyVAD so the listen pipeline always has a working VAD.
    private nonisolated static func makeVAD(
        engine: String,
        energyThreshold: Float,
        logBus: LogBus
    ) -> any VAD {
        let preferSilero = engine == "auto" || engine == "silero"
        if preferSilero {
            if let silero = SileroVAD.tryDefault() {
                Task {
                    await logBus.publish(.sidecarLog(
                        sidecar: "voice",
                        level: .info,
                        message: "VAD engine: silero (CoreML)",
                        fields: [:]
                    ))
                }
                return silero
            }
            // Silero requested but model missing — explain how to fix
            // and fall back. The fallback still gives a working voice
            // pipeline; the user just doesn't get the ML-detector
            // benefit until they run `scripts/download-models.sh`.
            if engine == "silero" {
                Task {
                    await logBus.publish(.error(
                        scope: "voice/vad",
                        message: "Silero VAD requested but model not found; run scripts/download-models.sh. Falling back to EnergyVAD.",
                        recoverable: true
                    ))
                }
            }
        }
        let config = EnergyVAD.Config(rmsThreshold: energyThreshold)
        return EnergyVAD(config: config)
    }

    /// FastPath factory. Wires per-intent handlers that invoke the
    /// just-registered tools directly and format the result in
    /// Rocky's persona. Each handler's reply is the literal text
    /// that the engine yields as the assistant turn — no brain
    /// inference happens for matched queries. Handlers return nil
    /// to signal "I can't fast-path this — escalate to the brain
    /// after all" (the matcher then falls through).
    private nonisolated static func makeFastPath(
        registry: ToolRegistry, logBus: LogBus
    ) async -> FastPath {
        let fastPath = FastPath()

        // Time
        await fastPath.register(.time) { _ in
            let result = await registry.invoke(
                name: "get_current_time", argumentsJSON: "{}",
                llmMessageId: "fast-path"
            )
            guard result.ok else { return nil }
            // The TimeTool already returns a `narrative` field that's
            // formatted in Rocky's voice ("Rocky see eight forty.
            // Tuesday."). Pass through.
            if let json = try? JSONValue(jsonString: result.resultJSON),
               let n = json.asObject?["narrative"]?.asString {
                return n
            }
            return nil
        }

        // Weather
        await fastPath.register(.weather) { match in
            // Optional location capture group (`weather in Berlin`).
            let location = match.groups.first ?? ""
            var args: [String: JSONValue] = [:]
            if !location.isEmpty {
                args["location"] = .string(location)
            }
            let argsJSON: String = JSONValue.object(args).encodedString()
            let result = await registry.invoke(
                name: "get_weather", argumentsJSON: argsJSON,
                llmMessageId: "fast-path"
            )
            guard result.ok else { return nil }
            if let json = try? JSONValue(jsonString: result.resultJSON),
               let n = json.asObject?["narrative"]?.asString {
                return n
            }
            return nil
        }

        // Calendar
        await fastPath.register(.calendar) { match in
            // Map captured "tomorrow" / "this week" → days_ahead int.
            let when = match.groups.first ?? ""
            let daysAhead: Int
            switch when {
            case "today":     daysAhead = 0
            case "tomorrow":  daysAhead = 1
            case "this week": daysAhead = 7
            case "next week": daysAhead = 14
            default:          daysAhead = 0
            }
            let argsJSON = "{\"days_ahead\": \(daysAhead)}"
            let result = await registry.invoke(
                name: "read_calendar", argumentsJSON: argsJSON,
                llmMessageId: "fast-path"
            )
            guard result.ok else { return nil }
            if let json = try? JSONValue(jsonString: result.resultJSON),
               let n = json.asObject?["narrative"]?.asString {
                return n
            }
            return nil
        }

        // Web search
        await fastPath.register(.search) { match in
            let query = match.groups.first ?? ""
            guard !query.isEmpty else { return nil }
            let escaped = query.replacingOccurrences(of: "\"", with: "\\\"")
            let argsJSON = "{\"query\": \"\(escaped)\"}"
            let result = await registry.invoke(
                name: "search_web", argumentsJSON: argsJSON,
                llmMessageId: "fast-path"
            )
            guard result.ok else { return nil }
            if let json = try? JSONValue(jsonString: result.resultJSON),
               let n = json.asObject?["narrative"]?.asString {
                return n
            }
            return nil
        }

        // Remember
        await fastPath.register(.remember) { match in
            let what = match.groups.first ?? ""
            guard !what.isEmpty else { return nil }
            let escaped = what.replacingOccurrences(of: "\"", with: "\\\"")
            let argsJSON = "{\"text\": \"\(escaped)\"}"
            let result = await registry.invoke(
                name: "remember", argumentsJSON: argsJSON,
                llmMessageId: "fast-path"
            )
            guard result.ok else { return nil }
            return "Rocky remember."
        }

        // Greeting — no tool needed.
        await fastPath.register(.greeting) { _ in
            "Hello. Rocky here."
        }

        await logBus.publish(.sidecarLog(
            sidecar: "cognition", level: .info,
            message: "fast-path: \(FastPath.Intent.allCases.count) intents wired",
            fields: [:]
        ))
        return fastPath
    }

    /// Wake-word engine factory: resolves `settings.wakeEngine`
    /// to a concrete implementation. If "porcupine" is requested
    /// but the framework isn't vendored, falls back to STT-derived
    /// wake with a logged warning.
    private nonisolated static func makeWakeEngine(
        engine: String,
        logBus: LogBus
    ) -> any WakeWordEngine {
        if engine == "porcupine" {
            // Stub today — see PorcupineStubEngine for the
            // requirements to flip this to working.
            Task {
                await logBus.publish(.error(
                    scope: "voice/wake",
                    message: "Porcupine wake engine selected but not yet integrated; falling back to STT-derived wake.",
                    recoverable: true
                ))
            }
            return STTWakeEngine()
        }
        return STTWakeEngine()
    }

    private nonisolated static func devTTSManifest(
        backend: String,
        model: String = ""
    ) -> SidecarManifest {
        // v0.4+: Chatterbox 8-bit is the default. Outperforms every
        // other cloning model on mlx-audio 0.4.3 by a wide margin
        // (0.15× RTF on Apple Silicon vs ~1.4× for Qwen3-TTS 1.7B).
        // Qwen3-TTS, Fish, and the others stay available as picker
        // options; all load via mlx-audio in the same venv.
        let resolved: String
        switch backend.lowercased() {
        case "chatterbox", "chatterbox-turbo", "chatterbox-fp16",
             "chatterbox-turbo-fp16", "chatterbox-8bit", "mlx", "auto", "":
            resolved = "chatterbox"
        case "qwen3-tts", "qwen3", "qwen":
            resolved = "qwen3-tts"
        case "fish", "fish-tts":
            resolved = "fish"
        default:
            resolved = backend
        }
        let venvPython = SidecarSupervisor.defaultVenvDir(for: "mlx-tts")
            .appendingPathComponent("bin/python")
        let sidecarDir = locateSidecarDir(named: "mlx-tts")?
            .path(percentEncoded: false) ?? "."
        // Build the env. `ROCKY_TTS_<BACKEND>_MODEL` overrides each
        // backend's default HF repo when the user supplies one. Empty
        // string means "let the backend use its built-in default".
        var env: [String: String] = [
            "PYTHONPATH": sidecarDir,
            "ROCKY_TTS_BACKEND": resolved,
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            switch resolved {
            case "chatterbox":
                env["ROCKY_TTS_CHATTERBOX_MODEL"] = trimmedModel
            case "qwen3-tts":
                env["ROCKY_TTS_QWEN3_MODEL"] = trimmedModel
            case "fish":
                env["ROCKY_TTS_FISH_MODEL"] = trimmedModel
            default:
                // Unknown backend — set a generic ROCKY_TTS_MODEL so
                // future backends can pick it up without code change.
                env["ROCKY_TTS_MODEL"] = trimmedModel
            }
        }
        return SidecarManifest(
            name: "mlx-tts",
            version: "0.2.0-dev",
            binary: venvPython.path,
            args: ["-u", "-m", "rocky_tts.runner"],
            workingDir: sidecarDir,
            env: env,
            readyTimeoutS: 30,
            shutdownGraceS: 3,
            // First synth includes a model load (~5–10s); bump the
            // synthesize timeout to cover the cold start.
            timeouts: [
                "*": 5,
                "synthesize": 60,
                "synthesize_stream": 60,
            ]
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
            version: "0.2.0-dev",
            binary: venvPython.path,
            args: ["-u", "-m", "rocky_robot_mic.runner"],
            workingDir: dir,
            env: [
                "PYTHONPATH": dir,
                // v0.2: sidecar is a WebSocket subscriber to the
                // on-bot `rocky_media_relay` Reachy Mini App (port
                // 8042 by default — the app's `custom_app_url`).
                // ROCKY_ROBOT_PORT is no longer used by this
                // sidecar; the daemon's REST API on :8000 is hit by
                // Swift directly elsewhere.
                "ROCKY_ROBOT_HOST": "reachy-mini.local",
                "ROCKY_RELAY_PORT": "8042",
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
            version: "0.2.0-dev",
            binary: venvPython.path,
            args: ["-u", "-m", "rocky_robot_camera.runner"],
            workingDir: dir,
            env: [
                "PYTHONPATH": dir,
                // v0.2: same WebSocket subscriber pattern as
                // robot-mic. FPS / width / quality are now set
                // on the bot-side relay app, not here — the relay
                // does the JPEG encode using its own constants.
                "ROCKY_ROBOT_HOST": "reachy-mini.local",
                "ROCKY_RELAY_PORT": "8042",
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
