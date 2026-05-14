import SwiftUI
import AppKit
import AVFoundation
import CoreLocation
import EventKit
import Speech
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics
import Perception

/// Macroscopic shell for the macOS Settings scene. Per
/// `docs/concepts/cockpit-design.md` §7, settings live in a separate
/// window with six tabs (Robot, Brain, Voice, Memory, Faces, Persona).
/// Apply-on-commit per field where safe; the robot endpoint is the
/// sole exception (relaunch-required, so it stages with a dedicated
/// Apply button).
///
/// Each tab body uses `Form` for native macOS spacing and label
/// alignment. The tabs all share the surrounding `TabView`'s padding
/// and the same minimum width so switching tabs doesn't reflow the
/// window.
struct SettingsView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        TabView {
            RobotSettingsTab()
                .tabItem { Label("Robot", systemImage: "antenna.radiowaves.left.and.right") }
            BrainSettingsTab()
                .tabItem { Label("Brain", systemImage: "brain") }
            VoiceSettingsTab()
                .tabItem { Label("Voice", systemImage: "speaker.wave.2") }
            MemorySettingsTab()
                .tabItem { Label("Memory", systemImage: "tray.full") }
            FacesSettingsTab()
                .tabItem { Label("Faces", systemImage: "person.crop.rectangle.stack") }
            PersonaSettingsTab()
                .tabItem { Label("Persona", systemImage: "text.quote") }
            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "checkmark.shield") }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 460)
    }
}

// MARK: - Robot tab

/// Robot endpoint. Host + port require a relaunch (URLSession sockets
/// + sidecars hold the original endpoint), so we keep a draft + Apply
/// here. The tab also surfaces the daemon status with a probe-now
/// button so the user can verify connectivity without leaving the
/// window.
private struct RobotSettingsTab: View {
    @Environment(AppServices.self) private var services
    @State private var hostDraft: String = ""
    @State private var portDraft: String = ""

    var body: some View {
        Form {
            Section {
                TextField("Host", text: $hostDraft, prompt: Text("reachy-mini.local"))
                TextField("Port", text: $portDraft, prompt: Text("8000"))
                    .frame(maxWidth: 120)
            } header: {
                Text("Robot endpoint")
            } footer: {
                Text("Endpoint changes take effect at next launch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("Daemon") { reachabilityLabel }
                LabeledContent("Probe") {
                    Button {
                        Task { await services.probeRobotPublic() }
                    } label: {
                        Label("Probe now", systemImage: "arrow.clockwise")
                    }
                }
            }

            Section("Storage") {
                LabeledContent("Application support") {
                    Text("~/Library/Application Support/Rocky/")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { services.settings.onBotMotionGuardEnabled },
                    set: { services.settings.onBotMotionGuardEnabled = $0 }
                )) {
                    Text("Route motion through on-bot guard (port 8042)")
                }
            } header: {
                Text("Motion safety")
            } footer: {
                Text("When ON, all motion commands (set_target, goto, play_emotion, wake_up, sleep, set_motor_mode, stop) are sent to the on-bot relay's `/api/motion/*` endpoints — the relay enforces slew, velocity, duration floor, single-in-flight, shelf-safe allowlist, and the 65° head-body yaw delta cap BEFORE forwarding to the daemon. Defence-in-depth alongside the Mac-side MotionGuard. Turn OFF only if running against an older bot whose relay doesn't yet have the v0.2 motion endpoints. Applies at next launch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            applyRow
        }
        .formStyle(.grouped)
        .onAppear {
            hostDraft = services.settings.robotHost
            portDraft = String(services.settings.robotPort)
        }
    }

    @ViewBuilder
    private var reachabilityLabel: some View {
        switch services.daemonReachability {
        case .online:
            Label("Online", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .offline(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .unknown:
            Label("Checking…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        }
    }

    private var dirty: Bool {
        hostDraft.trimmingCharacters(in: .whitespaces) != services.settings.robotHost
            || portDraft != String(services.settings.robotPort)
    }

    @ViewBuilder
    private var applyRow: some View {
        if dirty {
            HStack {
                Spacer()
                Text("Will apply at next launch.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("Apply") {
                    services.settings.robotHost =
                        hostDraft.trimmingCharacters(in: .whitespaces)
                    if let p = Int(portDraft.trimmingCharacters(in: .whitespaces)) {
                        services.settings.robotPort = p
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Brain tab

/// LLM endpoint. Hot-reloads on edit via `applySettings()` — no Apply
/// button, no relaunch. The model picker is sourced live from LM
/// Studio's `/v1/models` so changing models is one click.
private struct BrainSettingsTab: View {
    @Environment(AppServices.self) private var services
    @State private var lmURLDraft: String = ""
    @State private var lmApiKeyDraft: String = ""
    @State private var customMlxModelDraft: String = ""
    @State private var showingCustomMlxField: Bool = false

    /// Curated MLX-VLM models. The first entry is the v0.2 default.
    /// "Other…" lets the user paste any HF model id mlx-vlm supports.
    private static let mlxModelOptions: [(id: String, label: String)] = [
        ("mlx-community/Qwen3-VL-4B-Instruct-4bit",
         "Qwen3-VL 4B Instruct (4-bit, ~2.5 GB) — recommended"),
        ("mlx-community/Qwen3-VL-30B-A3B-Instruct-4bit",
         "Qwen3-VL 30B-A3B Instruct (4-bit, ~17 GB) — bigger Macs"),
        ("mlx-community/Qwen3-VL-30B-A3B-Instruct-8bit",
         "Qwen3-VL 30B-A3B Instruct (8-bit, ~30 GB)"),
        ("mlx-community/Qwen3-VL-235B-A22B-Instruct-4bit",
         "Qwen3-VL 235B-A22B Instruct (4-bit, ~120 GB) — Studio Ultra"),
    ]

    var body: some View {
        Form {
            backendSection
            switch services.settings.brainBackend {
            case "lm-studio":
                lmStudioSection
            case "mlx-vlm":
                mlxVLMSection
            default:  // "auto"
                mlxVLMSection
                lmStudioSection
            }
            webSearchSection
            conversationDisplaySection
            statusSection
        }
        .formStyle(.grouped)
        .onAppear {
            lmURLDraft = services.settings.lmStudioURL
            lmApiKeyDraft = services.settings.lmStudioApiKey
            customMlxModelDraft = services.settings.brainModel
            showingCustomMlxField = !Self.mlxModelOptions.contains {
                $0.id == services.settings.brainModel
            }
        }
    }

    // MARK: - Backend picker

    private var backendSection: some View {
        Section {
            Picker("Backend", selection: Binding(
                get: { services.settings.brainBackend },
                set: { newValue in
                    services.settings.brainBackend = newValue
                    Task { await services.applyBrainBackend() }
                }
            )) {
                Text("Auto — MLX-VLM if installed, else LM Studio")
                    .tag("auto")
                Text("MLX-VLM (native MLX, vision-aware)")
                    .tag("mlx-vlm")
                Text("LM Studio (HTTP, text-only)")
                    .tag("lm-studio")
            }
        } header: {
            Text("Brain")
        } footer: {
            Text("Auto picks MLX-VLM when the brain sidecar venv is installed (`Sidecars/brain/setup.sh`). MLX-VLM runs natively on Apple Silicon — no HTTP hop, vision-aware, native tool calling.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - MLX-VLM section

    private var mlxVLMSection: some View {
        Section {
            Picker("Model", selection: Binding<String>(
                get: {
                    let cur = services.settings.brainModel
                    if Self.mlxModelOptions.contains(where: { $0.id == cur }) {
                        return cur
                    }
                    return "__custom__"
                },
                set: { newValue in
                    if newValue == "__custom__" {
                        showingCustomMlxField = true
                    } else {
                        showingCustomMlxField = false
                        services.settings.brainModel = newValue
                        Task { await services.applyBrainBackend() }
                    }
                }
            )) {
                ForEach(Self.mlxModelOptions, id: \.id) { opt in
                    Text(opt.label).tag(opt.id)
                }
                Text("Other (HF model id or local path)").tag("__custom__")
            }

            if showingCustomMlxField {
                HStack {
                    TextField(
                        "HF id or local path",
                        text: $customMlxModelDraft,
                        prompt: Text("mlx-community/… or /Users/you/Models/…")
                    )
                    .font(.body.monospaced())
                    .onSubmit { commitCustomMlxModel() }
                    Button("Choose folder…") { chooseMlxModelFolder() }
                        .help("Pick a local directory containing the mlx-vlm model files (config.json, weights, processor, etc.). The path is sent to the brain sidecar via ROCKY_BRAIN_MODEL.")
                    Button("Apply") { commitCustomMlxModel() }
                        .disabled(
                            customMlxModelDraft.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                }
            }

            LabeledContent("Sidecar status") {
                brainSidecarStatusLabel
            }
            HStack {
                Spacer()
                Button {
                    Task { await services.applyBrainBackend() }
                } label: {
                    Label("Restart brain", systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text("MLX-VLM")
        } footer: {
            Text("Custom field accepts EITHER a Hugging Face repo id (`mlx-community/…`) OR a local filesystem path (e.g. `/Users/you/Models/Qwen3-VL-4B`, or `~/Models/…`). Use **Choose folder…** to browse for a local directory. HF-id first-run downloads ~2.5 GB of weights into ~/.cache/huggingface/. Switching models hot-swaps the sidecar — the next chat uses the new model. Restart Brain manually if the sidecar got into a bad state.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var brainSidecarStatusLabel: some View {
        let state = services.brainSidecarState
        switch state {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .starting:
            Label("Starting…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .stopped:
            Label("Not running", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .failing(let r):
            Label("Failing: \(r)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        case .circuitOpen(let until):
            Label("Backing off until \(until.formatted(.dateTime.hour().minute().second()))",
                  systemImage: "exclamationmark.octagon")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    // MARK: - LM Studio section (fallback / explicit choice)

    private var lmStudioSection: some View {
        Section {
            TextField("Base URL", text: $lmURLDraft,
                      prompt: Text("http://localhost:1234/v1"))
                .onSubmit { commitURL() }
            modelPicker
            SecureField("API key", text: $lmApiKeyDraft,
                        prompt: Text("(blank for none)"))
                .onSubmit { commitAPIKey() }
        } header: {
            Text("LM Studio")
        } footer: {
            Text("HTTP fallback for the brain. Submitted fields hot-reload the cognition engine. No relaunch needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Web search

    private var webSearchSection: some View {
        Section {
            // Direct binding to the store — no draft state, no
            // dependence on `.onSubmit` firing (which only fires
            // when the user presses Return; paste-and-click-away
            // wouldn't commit). Brave key has no hot-reload
            // cost, so writing on every character change is
            // fine; UserDefaults batches the writes.
            SecureField(
                "Brave Search API key",
                text: Binding(
                    get: { services.settings.braveSearchAPIKey },
                    set: { services.settings.braveSearchAPIKey = $0 }
                ),
                prompt: Text("paste from search.brave.com/api")
            )
        } header: {
            Text("Web search")
        } footer: {
            Text("Used by the `search_web` tool. Free tier allows 1 query/sec; leave blank to disable web search.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Conversation display

    private var conversationDisplaySection: some View {
        Section {
            Toggle("Show tool calls in chat",
                   isOn: Binding(
                       get: { services.settings.showToolCalls },
                       set: { services.settings.showToolCalls = $0 }
                   ))
            Toggle("Profiling mode",
                   isOn: Binding(
                       get: { services.settings.profilingEnabled },
                       set: { newValue in
                           services.settings.profilingEnabled = newValue
                           Task { await services.applySettings() }
                       }
                   ))
        } header: {
            Text("Conversation")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("When off, the small `⌘ → tool · args` and `⌘ ← tool (ok, Nms) · result` lines are hidden between bubbles. Tool activity is still recorded in the Activity tab and the log.")
                Text("Profiling mode emits one end-to-end timing line per turn to the Logs view: VAD → STT → AddressFilter → brain → tools → TTS, so you can see exactly where the latency is.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("LM Studio") { llmLabel }
            LabeledContent("Re-probe") {
                Button {
                    Task { await services.probeLMStudioPublic() }
                } label: {
                    Label("Probe", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: - Helpers

    private var modelPicker: some View {
        let models = services.availableLLMModels
        let store = services.settings
        return Picker("Model", selection: Binding(
            get: { store.lmStudioModel },
            set: { newValue in
                store.lmStudioModel = newValue
                Task { await services.applySettings() }
            }
        )) {
            // Stable tag for the current value even when not in the list
            // — prevents "selection invalid" warnings when LM Studio is
            // offline or the model isn't loaded.
            if !models.contains(store.lmStudioModel) {
                Text(store.lmStudioModel.isEmpty
                     ? "—"
                     : "\(store.lmStudioModel) (not loaded)")
                    .tag(store.lmStudioModel)
            }
            ForEach(models, id: \.self) { m in
                Text(m).tag(m)
            }
        }
    }

    @ViewBuilder
    private var llmLabel: some View {
        switch services.llmStatus {
        case .online(let model):
            Label(model, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(1)
        case .offline(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .unknown:
            Label("Checking…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        }
    }

    private func commitURL() {
        let trimmed = lmURLDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed != services.settings.lmStudioURL else { return }
        services.settings.lmStudioURL = trimmed
        Task { await services.applySettings() }
    }

    private func commitAPIKey() {
        guard lmApiKeyDraft != services.settings.lmStudioApiKey else { return }
        services.settings.lmStudioApiKey = lmApiKeyDraft
        Task { await services.applySettings() }
    }

    private func commitCustomMlxModel() {
        let trimmed = customMlxModelDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed != services.settings.brainModel else { return }
        services.settings.brainModel = trimmed
        Task { await services.applyBrainBackend() }
    }

    /// Show an `NSOpenPanel` to pick a local directory containing the
    /// mlx-vlm model files. The directory's absolute path goes into
    /// the model field — the sidecar (`runner.py`) will detect a path
    /// prefix and call `mlx_vlm.load` with the resolved local path
    /// instead of trying to hit Hugging Face.
    private func chooseMlxModelFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose MLX-VLM model folder"
        panel.message = "Pick the folder that contains config.json, the model weights, and the processor files."
        panel.prompt = "Select model"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let cur = URL(string: customMlxModelDraft),
           cur.isFileURL,
           FileManager.default.fileExists(atPath: cur.path)
        {
            panel.directoryURL = cur.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            customMlxModelDraft = url.path
            commitCustomMlxModel()
        }
    }
}

// MARK: - Voice tab

/// Microphone source + TTS engine + speaker volume. Source / engine
/// changes are saved instantly but only take effect on the next listen
/// toggle / next launch (the underlying sidecars hold the original
/// configuration); the volume slider applies live via PCM scaling
/// during synthesis.
private struct VoiceSettingsTab: View {
    @Environment(AppServices.self) private var services
    @State private var calibrating: Bool = false

    var body: some View {
        Form {
            Section {
                Picker("Source", selection: micSourceBinding) {
                    Text("Robot mic (Reachy 4-mic array)").tag("robot")
                    Text("Mac mic (built-in / system)").tag("mac")
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Robot mic uses Reachy's 4-mic ReSpeaker array via WebRTC. " +
                     "Run ./Sidecars/robot-mic/setup.sh once. Source change " +
                     "applies on the next Listen toggle.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("VAD engine", selection: vadEngineBinding) {
                    Text("Auto — Silero if installed, else Energy").tag("auto")
                    Text("Silero VAD (CoreML, ML-based)").tag("silero")
                    Text("Energy threshold (RMS, simplest)").tag("energy")
                }
                MicSensitivityRow(calibrating: $calibrating)
            } header: {
                Text("Voice activity detection")
            } footer: {
                Text("Silero recognises speech (pitched, formant-shaped) and ignores chair scrapes, fan ticks, mouse clicks. Run `./scripts/download-models.sh silero` to install the CoreML model. Engine change applies on next Listen toggle. Threshold semantics differ between engines (RMS for Energy, probability for Silero).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("STT engine", selection: sttEngineBinding) {
                    Text("Auto — MLX-Whisper → WhisperKit → Apple Speech").tag("auto")
                    Text("MLX-Whisper (whisper-large-v3-mlx, via sidecar)").tag("mlx-whisper")
                    Text("WhisperKit (whisper-large-v3-turbo, CoreML)").tag("whisperkit")
                    Text("Apple Speech (SFSpeechRecognizer)").tag("apple")
                }
            } header: {
                Text("Speech-to-text")
            } footer: {
                Text("MLX-Whisper runs whisper-large-v3-mlx via the mlx-stt sidecar — same MLX runtime as the brain and TTS. Run `./Sidecars/mlx-stt/setup.sh` to install (~3 GB on first transcribe). WhisperKit uses CoreML weights at ~700 MB. Apple Speech is the system fallback. Auto tries them in order; the first one that loads wins. Engine change applies on next launch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Wake phrase", text: wakeWordBinding,
                          prompt: Text("rocky"))
                Picker("Wake engine", selection: wakeEngineBinding) {
                    Text("STT-derived (uses transcript)").tag("stt")
                    Text("Porcupine (placeholder — not yet integrated)")
                        .tag("porcupine")
                }
                Toggle("Wake on chassis tap / loud sound",
                       isOn: wakeOnPatBinding)
            } header: {
                Text("Wake word")
            } footer: {
                Text("Lower-case stored. STT-derived is the v0.1 path: WakeFilter pattern-matches the wake phrase in the final transcript. Porcupine slot is reserved for a future dedicated keyword spotter (97% accuracy, ~50 ms latency). Wake-phrase change applies on next launch.\n\nWake-on-tap routes any loud sound (RMS > 0.03) into a wake. Off by default — the on-robot mic hears Rocky's own goodnight TTS and ambient noise, which immediately undoes a sleep command.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("TTS engine", selection: ttsBackendBinding) {
                    Text("Chatterbox 8-bit (fastest, 0.15× RTF) — recommended")
                        .tag("chatterbox")
                    Text("Qwen3-TTS-12Hz 1.7B (multilingual, 0.36× RTF in 8-bit)")
                        .tag("qwen3-tts")
                    Text("Fish Audio S2 Pro (high-quality clone, ~1× RTF)")
                        .tag("fish-audio")
                }
                HStack {
                    TextField("HF model id (blank = engine default)",
                              text: ttsModelBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .help("Hugging Face repo id of the TTS model — e.g. mlx-community/chatterbox-8bit, mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16. Leave empty to use the engine's built-in default.")
                    Button("Clear") {
                        services.settings.ttsModel = ""
                    }
                    .disabled(services.settings.ttsModel.isEmpty)
                }
                BotVolumeSlider()
            } header: {
                Text("Voice (TTS)")
            } footer: {
                Text("RTF = wall-time-to-synth ÷ audio-duration (lower = faster). Chatterbox 8-bit is the fastest cloning model and the default. The HF model id field overrides the engine's built-in model so you can point to any compatible repo on the same engine (e.g. another chatterbox variant). All engines pick up the reference clone from `~/Library/Application Support/Rocky/voice/sample.wav` + `sample.txt`. Engine and model changes apply on next launch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $calibrating) {
            MicCalibrationView()
                .environment(services)
        }
    }

    private var micSourceBinding: Binding<String> {
        let store = services.settings
        return Binding(get: { store.micSource },
                       set: { store.micSource = $0 })
    }

    private var ttsBackendBinding: Binding<String> {
        let store = services.settings
        return Binding(get: { store.ttsBackend },
                       set: { store.ttsBackend = $0 })
    }

    private var ttsModelBinding: Binding<String> {
        let store = services.settings
        return Binding(get: { store.ttsModel },
                       set: { store.ttsModel = $0 })
    }

    private var vadEngineBinding: Binding<String> {
        let store = services.settings
        return Binding(get: { store.vadEngine },
                       set: { store.vadEngine = $0 })
    }

    private var sttEngineBinding: Binding<String> {
        let store = services.settings
        return Binding(get: { store.sttEngine },
                       set: { store.sttEngine = $0 })
    }

    private var wakeWordBinding: Binding<String> {
        let store = services.settings
        return Binding(
            get: { store.wakeWord },
            set: { store.wakeWord = $0.lowercased() }
        )
    }

    private var wakeOnPatBinding: Binding<Bool> {
        let store = services.settings
        return Binding(get: { store.wakeOnPat },
                       set: { store.wakeOnPat = $0 })
    }

    private var wakeEngineBinding: Binding<String> {
        let store = services.settings
        return Binding(get: { store.wakeEngine },
                       set: { store.wakeEngine = $0 })
    }
}

// MARK: - Memory tab

/// Memory recall toggle + top-K slider + drawer count + forget. All
/// existing controls re-homed from the old long-scroll into a focused
/// tab. Each control already commits-on-change.
private struct MemorySettingsTab: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Form {
            Section {
                MemoryStatusLine()
                MemoryRecallToggle()
                MemoryTopKSlider()
            } header: {
                Text("Recall")
            } footer: {
                Text("Rocky stores every user and assistant utterance verbatim, " +
                     "then pulls the most relevant snippets into the next reply. " +
                     "Storage is local — see ~/Library/Application Support/Rocky/Memory.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Manage") {
                MemoryForgetButton()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Faces tab

/// Enrolment + threshold + the list of known people.
private struct FacesSettingsTab: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        // Snapshot once per body eval — EnrolledFacesList doesn't read
        // services, so its identity stays stable across services-driven
        // re-renders.
        let people = services.enrolledPeople
        return Form {
            Section {
                EnrollFaceForm()
            } header: {
                Text("Add a face")
            } footer: {
                Text("Rocky says \u{201C}hey\u{201D} when he recognises someone. " +
                     "Add a name, an optional phonetic spelling for TTS, and one " +
                     "or more photos.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Match threshold") {
                FaceMatchThresholdSlider()
            }

            if !people.isEmpty {
                Section("Enrolled (\(people.count))") {
                    EnrolledFacesList(people: people)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Persona tab

/// Full-width, full-height TextEditor for Rocky's system prompt. Hot-
/// reloads on edit (debounced — saves every time the user pauses for
/// 1 s) so the next turn picks up the new persona without an Apply
/// button.
private struct PersonaSettingsTab: View {
    @Environment(AppServices.self) private var services
    @State private var draft: String = ""
    @State private var savedAt: Date?
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Persona")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Reset to default") {
                    draft = SettingsStore.defaultPersona
                    commit()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Text("System prompt the LLM sees on every turn. Edits hot-reload — " +
                 "the next turn uses the new persona. Auto-saves on pause.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $draft)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: draft) { _, _ in scheduleCommit() }

            HStack {
                Text("\(draft.count) characters")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let savedAt {
                    Label("Saved \(savedAt.formatted(.dateTime.hour().minute().second()))",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.horizontal, 4)
        .onAppear { draft = services.settings.persona }
    }

    private func scheduleCommit() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            commit()
        }
    }

    private func commit() {
        guard draft != services.settings.persona else { return }
        services.settings.persona = draft
        Task {
            await services.applySettings()
            await MainActor.run { savedAt = Date() }
        }
    }
}

/// Self-contained enrollment form. Owns its own `@State` for the form
/// fields and never reads any `services.*` property in its body, so
/// services-driven UI mutations elsewhere (camera frames, robot state,
/// face detections) cannot invalidate it and steal TextField focus.
private struct EnrollFaceForm: View {
    @Environment(AppServices.self) private var services

    @State private var name: String = ""
    @State private var pronunciation: String = ""
    @State private var photos: [Data] = []
    @State private var error: String?
    @State private var submitting: Bool = false
    @State private var pronouncing: Bool = false

    var body: some View {
        // A two-column grid (label / control) instead of a nested
        // `Form { .formStyle(.grouped) }`. Nesting a grouped Form
        // inside the parent grouped Form was the bug: LabeledContent
        // inside a nested grouped form collapses the trailing control
        // to right-aligned static text, which is why "Alice" rendered
        // as a label and "phonetic spelling…" wrapped centred.
        //
        // Grid with leading/firstTextBaseline alignment gives the
        // same trailing-control feel as System Settings without the
        // nested-Form glitches, and lets the hint + photo strip
        // attach naturally below the row they belong to.
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: 12,
             verticalSpacing: 10) {
            GridRow {
                Text("Name")
                    .gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                TextField("Alice", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            GridRow {
                Text("Says")
                    .gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TextField("phonetic spelling (optional)",
                                  text: $pronunciation)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            speakPronunciationTest()
                        } label: {
                            Image(systemName: pronouncing
                                  ? "speaker.wave.2.fill"
                                  : "play.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .font(.title3)
                                .symbolEffect(.pulse, isActive: pronouncing)
                        }
                        .buttonStyle(.borderless)
                        .disabled(pronunciationTestDisabled)
                        .help(pronunciationHelp)
                        .accessibilityLabel("Test pronunciation")
                    }
                    Text("e.g. \u{201C}shi-vawn\u{201D} for Siobhán")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GridRow(alignment: .firstTextBaseline) {
                Text("Photos")
                    .gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            choosePhotos()
                        } label: {
                            Label("Choose photos\u{2026}",
                                  systemImage: "photo.on.rectangle.angled")
                        }
                        Button {
                            useCameraFrame()
                        } label: {
                            Label("Use current frame", systemImage: "camera")
                        }
                    }
                    if !photos.isEmpty {
                        photoStrip
                    }
                }
            }

            if let err = error {
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GridRow {
                Color.clear.frame(width: 0, height: 0)
                HStack {
                    Spacer()
                    Button {
                        Task { await submit() }
                    } label: {
                        if submitting {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Adding\u{2026}")
                            }
                        } else {
                            Label("Add face",
                                  systemImage: "person.fill.badge.plus")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        submitting
                        || name.trimmingCharacters(in: .whitespaces).isEmpty
                        || photos.isEmpty
                    )
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Subviews

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(photos.enumerated()), id: \.offset) { idx, data in
                    ZStack(alignment: .topTrailing) {
                        if let img = NSImage(data: data) {
                            Image(nsImage: img)
                                .resizable()
                                .interpolation(.medium)
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.gray.opacity(0.2))
                                .frame(width: 64, height: 64)
                        }
                        Button {
                            photos.remove(at: idx)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .background(Circle().fill(.black.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .padding(3)
                    }
                }
            }
        }
        .frame(height: 72)
    }

    // MARK: - Actions (run on Button taps; do not register SwiftUI deps)

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .jpeg, .png, .heic]
        panel.message = "Choose one or more photos that clearly show the face."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let data = Self.loadImageAsJPEG(url: url) {
                photos.append(data)
            }
        }
    }

    private func useCameraFrame() {
        guard let frame = services.lastCameraFrame else {
            error = "No camera frame available yet — wait for the Vision card to show one."
            return
        }
        photos.append(frame.jpeg)
        error = nil
    }

    // MARK: - Pronunciation test

    /// Text to send through TTS for the pronunciation test. Uses the
    /// pronunciation field if non-empty, falls back to the name —
    /// that mirrors how the rest of the app treats the pronunciation:
    /// it overrides the displayed name when speaking, otherwise the
    /// name itself is spoken.
    private var pronunciationTestText: String {
        let pron = pronunciation.trimmingCharacters(in: .whitespaces)
        if !pron.isEmpty { return pron }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private var pronunciationTestDisabled: Bool {
        pronouncing || pronunciationTestText.isEmpty
    }

    private var pronunciationHelp: String {
        if !pronunciationTestText.isEmpty {
            return "Hear how Rocky says \u{201C}\(pronunciationTestText)\u{201D}."
        }
        return "Enter a name (or phonetic spelling) to hear how Rocky says it."
    }

    /// Send the pronunciation through Rocky's TTS so the user can hear
    /// whether the phonetic spelling produces the right sound before
    /// committing the enrollment. Plays through the robot speaker
    /// (same path as any other TTS).
    private func speakPronunciationTest() {
        let text = pronunciationTestText
        guard !text.isEmpty, !pronouncing else { return }
        pronouncing = true
        Task {
            do {
                _ = try await services.robotTTS.speak(text)
            } catch {
                await MainActor.run { self.error = "TTS test failed: \(error)" }
            }
            await MainActor.run { self.pronouncing = false }
        }
    }

    private func submit() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !photos.isEmpty else { return }
        submitting = true
        error = nil
        let success = await services.enrollFace(
            name: trimmed, pronunciation: pronunciation, photoJPEGs: photos
        )
        submitting = false
        if success {
            name = ""
            pronunciation = ""
            photos = []
        } else {
            error = "No face detected in those photos. Try a clearer shot or a different angle."
        }
    }

    private static func loadImageAsJPEG(url: URL) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }
}

/// Robot speaker output volume. Drags apply live by scaling the next
/// synthesized WAV's PCM samples — no daemon round-trip needed. The
/// underlying setting persists immediately.
/// Sensitivity row: live RMS readout, current threshold, manual
/// slider, and a Calibrate button. The slider lets the user fine-tune
/// after calibration; calibration produces a sane starting value, the
/// slider trims it.
private struct MicSensitivityRow: View {
    @Environment(AppServices.self) private var services
    @Binding var calibrating: Bool

    var body: some View {
        let threshold = services.settings.micVADThreshold
        let previous = services.settings.micVADThresholdPrevious
        let canRevert = abs(previous - threshold) > 0.0001
        let live = Double(services.lastMicRMS)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "VAD threshold")
                Spacer()
                Text(String(format: "%.4f", threshold))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                Text(String(format: "live %.4f", live))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(live >= threshold ? .green : .secondary)
            }
            Slider(
                value: Binding(
                    get: { services.settings.micVADThreshold },
                    set: { newValue in
                        // Direct slider drags also stamp `previous`
                        // so the user can undo a manual nudge.
                        services.settings.applyCalibratedThreshold(newValue)
                        let v = Float(newValue)
                        Task { await services.voice.setVADThreshold(v) }
                    }
                ),
                in: 0.001...0.05,
                step: 0.001
            ) {
                Text("Threshold")
            } minimumValueLabel: {
                Text("loud").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("quiet").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Text("Watch the \u{201C}live\u{201D} number while speaking — it should sit comfortably above the threshold for normal speech and drop below it during silence.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if canRevert {
                    // Surfaces only when there's something to undo.
                    // Tooltip carries the value so the user knows
                    // what they're going back to.
                    Button {
                        services.settings.applyCalibratedThreshold(previous)
                        let v = Float(previous)
                        Task { await services.voice.setVADThreshold(v) }
                    } label: {
                        Label("Revert", systemImage: "arrow.uturn.backward")
                    }
                    .help(String(format: "Restore previous threshold (%.4f)", previous))
                }
                Button { calibrating = true } label: {
                    Label("Calibrate…", systemImage: "mic.and.signal.meter")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct BotVolumeSlider: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let value = services.settings.audioVolume
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Robot speaker volume")
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(value > 1.0 ? .orange : .primary)
            }
            Slider(
                value: Binding(
                    get: { services.settings.audioVolume },
                    set: { newValue in
                        services.settings.audioVolume = newValue
                        Task { await services.robotTTS.setVolume(newValue) }
                    }
                ),
                // 0–300% — anything above 100% applies a software
                // gain boost (hard-clipped at int16 max) for the
                // case where the reference clip was recorded
                // quietly and the bot speaker is already fully open
                // on its own alsamixer.
                in: 0.0...3.0,
                step: 0.05
            ) {
                Text("Volume")
            } minimumValueLabel: {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Applied to every TTS clip before it's uploaded to the robot. 100% = no scaling. Values above 100% hard-clip — useful when a quiet reference clip leaves the cloned voice too soft, but they introduce clipping distortion. If you need more, re-record the reference louder or raise the bot's on-device alsamixer PCM gain.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Match-threshold slider with a live distance readout. Drags apply
/// instantly to `services.faceLibrary` so the user can tune by watching
/// the live bbox label in the Vision card flip from `?` to the name.
private struct FaceMatchThresholdSlider: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let threshold = services.settings.faceMatchThreshold
        let live = services.lastFaceDetection?.closestDistance
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Match threshold")
                Spacer()
                Text(String(format: "%.2f", threshold))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                if let liveD = live {
                    Text(String(format: "live %.2f", liveD))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(liveD <= threshold ? .green : .secondary)
                }
            }
            Slider(
                value: Binding(
                    get: { services.settings.faceMatchThreshold },
                    set: { newValue in
                        services.settings.faceMatchThreshold = newValue
                        Task { await services.faceLibrary.setAcceptThreshold(newValue) }
                    }
                ),
                in: 0.4...1.5,
                step: 0.05
            ) {
                Text("Threshold")
            } minimumValueLabel: {
                Text("strict").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("loose").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Lower = stricter; only very close matches accepted. Watch the \u{201C}live\u{201D} number while a face is on camera — set the threshold a touch higher than the distance you see for known people. Default 1.0.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Reads `services.*` only inside the row's onRemove / onTogglePrimary
/// closures, never in body — so the list itself doesn't churn with services.
private struct EnrolledFacesList: View {
    @Environment(AppServices.self) private var services
    let people: [FaceLibrary.Person]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(people) { person in
                FaceRow(
                    person: person,
                    onTogglePrimary: {
                        let target: UUID? = person.isPrimary ? nil : person.id
                        Task { await services.setPrimaryFace(id: target) }
                    },
                    onRemove: {
                        let id = person.id
                        Task { await services.removeFace(id: id) }
                    }
                )
            }
            Text("The starred face is the only one Rocky's head will track. Other recognised faces still get greeted when they come into view, but the head stays on the primary.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
}

private struct FaceRow: View {
    let person: FaceLibrary.Person
    let onTogglePrimary: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(person.name)
                        .font(.callout.weight(.medium))
                    if person.isPrimary {
                        Text("primary")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
                if !person.pronunciation.isEmpty {
                    Text("says \u{201C}\(person.pronunciation)\u{201D}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(person.samplesB64.count) sample\(person.samplesB64.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                onTogglePrimary()
            } label: {
                Image(systemName: person.isPrimary ? "star.fill" : "star")
                    .foregroundStyle(person.isPrimary ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(person.isPrimary
                  ? "Clear primary — Rocky will fall back to tracking the largest face."
                  : "Make \(person.name) the primary — Rocky will only track this face.")
            Button {
                onRemove()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove \(person.name) from the face library")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.gray.opacity(0.04))
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let firstSample = person.sampleData.first,
           let img = NSImage(data: firstSample) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.gray.opacity(0.2))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                )
        }
    }
}

// MARK: - Memory subviews

/// Read-only summary of the memory sidecar's state + drawer count.
private struct MemoryStatusLine: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let detail = stateDetail()
        HStack(spacing: 8) {
            Image(systemName: detail.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(detail.tint)
            Text(detail.text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await services.refreshMemoryCount() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Re-poll the sidecar for the current drawer count.")
        }
    }

    private func stateDetail() -> (icon: String, tint: Color, text: String) {
        switch services.memorySidecarState {
        case .stopped:
            return ("xmark.circle.fill", .gray,
                    "stopped — run Sidecars/mempalace/setup.sh")
        case .starting:
            return ("hourglass", .orange, "starting…")
        case .ready:
            let n = services.memoryDrawerCount
            let countText = n < 0
                ? "drawer count pending"
                : (n == 1 ? "1 drawer stored" : "\(n) drawers stored")
            return ("checkmark.circle.fill", .green, "online · " + countText)
        case .failing(let reason):
            return ("exclamationmark.triangle.fill", .red, "failing — " + reason)
        case .circuitOpen(let until):
            let s = max(0, Int(until.timeIntervalSinceNow))
            return ("exclamationmark.triangle.fill", .red, "cooldown · \(s)s")
        }
    }
}

/// "Recall prior conversations" toggle. When off, post-turn writes
/// still happen so a future re-enable has full history; only the
/// pre-turn recall step is skipped.
private struct MemoryRecallToggle: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Toggle(isOn: Binding(
            get: { services.settings.memoryRecallEnabled },
            set: { newValue in
                services.settings.memoryRecallEnabled = newValue
                Task { await services.applySettings() }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recall prior conversations").font(.callout.weight(.medium))
                Text("Inject the top-K most relevant snippets into each LLM turn. Writes always happen regardless.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}

/// Top-K slider — how many drawers to pull per recall.
private struct MemoryTopKSlider: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let value = services.settings.memoryTopK
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Snippets per recall (top-K)")
                Spacer()
                Text("\(value)")
                    .font(.caption.monospacedDigit().weight(.medium))
            }
            Slider(
                value: Binding(
                    get: { Double(services.settings.memoryTopK) },
                    set: { newValue in
                        let clamped = max(1, min(10, Int(newValue.rounded())))
                        if clamped != services.settings.memoryTopK {
                            services.settings.memoryTopK = clamped
                            Task { await services.applySettings() }
                        }
                    }
                ),
                in: 1...10,
                step: 1
            ) {
                Text("Top-K")
            } minimumValueLabel: {
                Text("1").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("10").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Lower keeps the prompt focused; higher gives more context at the cost of tokens and noise.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .disabled(!services.settings.memoryRecallEnabled)
        .opacity(services.settings.memoryRecallEnabled ? 1 : 0.45)
        .padding(.vertical, 4)
    }
}

/// Destructive "Forget everything" button. Confirms before wiping every
/// drawer in Rocky's wing/room. Disabled when memory is offline or empty.
private struct MemoryForgetButton: View {
    @Environment(AppServices.self) private var services
    @State private var confirming: Bool = false
    @State private var working: Bool = false
    @State private var lastResult: String?

    var body: some View {
        let isReady = services.memorySidecarState == .ready
        let isEmpty = services.memoryDrawerCount == 0
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(role: .destructive) {
                    confirming = true
                } label: {
                    Label("Forget everything", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(working || !isReady || isEmpty)

                if working {
                    ProgressView().controlSize(.small)
                }
                if let lastResult {
                    Text(lastResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Removes every stored drawer for the rocky / conversation room. Cannot be undone.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .alert("Forget every memory?",
               isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Forget everything", role: .destructive) {
                working = true
                Task {
                    let n = await services.forgetAllMemory()
                    await MainActor.run {
                        working = false
                        lastResult = "deleted \(n)"
                    }
                }
            }
        } message: {
            Text("This deletes every stored drawer in Rocky's palace. He won't remember any prior conversations after this.")
        }
    }
}

// MARK: - Permissions tab

/// Live view of the four TCC permissions Rocky uses, mirroring the
/// first-run "Grant access" step. Useful when a permission gets
/// revoked, when the user wants to re-prompt for one that was
/// denied, or just to confirm what's been granted. Status refreshes
/// on every render and on `NSApplication.didBecomeActive` (when the
/// user comes back from System Settings).
private struct PermissionsSettingsTab: View {
    @Environment(AppServices.self) private var services
    @State private var refreshTick = 0

    var body: some View {
        Form {
            Section {
                let auth = services.permissions
                if services.settings.micSource != "robot" {
                    permissionRow(
                        icon: "mic.fill",
                        title: "Microphone",
                        rationale: PermissionsAuthority.Permission.microphone.rationale,
                        status: micStatus,
                        anchor: PermissionsAuthority.Permission.microphone.settingsAnchor,
                        grant: { _ = await auth.request(.microphone) }
                    )
                }
                permissionRow(
                    icon: "waveform",
                    title: PermissionsAuthority.Permission.speechRecognition.displayName,
                    rationale: PermissionsAuthority.Permission.speechRecognition.rationale,
                    status: speechStatus,
                    anchor: PermissionsAuthority.Permission.speechRecognition.settingsAnchor,
                    grant: { _ = await auth.request(.speechRecognition) }
                )
                permissionRow(
                    icon: "calendar",
                    title: PermissionsAuthority.Permission.calendar.displayName,
                    rationale: PermissionsAuthority.Permission.calendar.rationale,
                    status: calendarStatus,
                    anchor: PermissionsAuthority.Permission.calendar.settingsAnchor,
                    grant: { _ = await auth.request(.calendar) }
                )
                permissionRow(
                    icon: "location.fill",
                    title: PermissionsAuthority.Permission.location.displayName,
                    rationale: PermissionsAuthority.Permission.location.rationale,
                    status: locationStatus,
                    anchor: PermissionsAuthority.Permission.location.settingsAnchor,
                    grant: { _ = await auth.request(.location) }
                )
            } header: {
                Text("System permissions")
            } footer: {
                Text("macOS shows the prompt the first time Rocky needs each permission. After that, denied entries can only be re-enabled in System Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            // The authority listens for `didBecomeActive` itself and
            // re-reads, but bumping the explicit refreshTick makes
            // the SwiftUI re-render deterministic in case @Observable
            // doesn't pick up a same-value mutation.
            services.permissions.refresh()
            refreshTick &+= 1
        }
        .id(refreshTick)
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: String,
        rationale: String,
        status: PermissionRowStatus,
        anchor: String,
        grant: @escaping @Sendable () async -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(rationale).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption.weight(.medium))
            case .limited(let reason):
                // Calendar `.writeOnly` is the canonical case. Show
                // the macOS-shaped label rather than collapsing to
                // "Denied" — the user granted *something*, just not
                // what Rocky needs.
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        Label("Limited", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption.weight(.medium))
                        Button("Open Settings") {
                            let url = URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
                            )!
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            case .denied:
                HStack(spacing: 6) {
                    Label("Denied", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption.weight(.medium))
                    Button("Open Settings") {
                        let url = URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
                        )!
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            case .unknown:
                Button("Grant") { Task { await grant() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Status readers
    //
    // All four permissions route through `services.permissions` so
    // the labels here match what the FirstRunOverlay shows AND what
    // the tools actually see. The mapping below is the only place
    // in this file that knows about the 5-state authority enum;
    // the row UI deals with three local cases plus a `.limited`
    // subtitle.

    private enum PermissionRowStatus: Equatable {
        case granted
        case limited(reason: String)
        case denied
        case unknown
    }

    private func mapStatus(_ s: PermissionsAuthority.Status) -> PermissionRowStatus {
        switch s {
        case .granted:                  return .granted
        case .limited(let reason):      return .limited(reason: reason)
        case .denied, .restricted:      return .denied
        case .notDetermined:            return .unknown
        }
    }

    private var micStatus: PermissionRowStatus {
        mapStatus(services.permissions.microphone)
    }
    private var speechStatus: PermissionRowStatus {
        mapStatus(services.permissions.speechRecognition)
    }
    private var calendarStatus: PermissionRowStatus {
        mapStatus(services.permissions.calendar)
    }
    private var locationStatus: PermissionRowStatus {
        mapStatus(services.permissions.location)
    }
}
