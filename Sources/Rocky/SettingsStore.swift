import Foundation
import Observation
import RobotLink
import Cognition

/// User-tunable settings persisted in `UserDefaults`. Read once at
/// `AppServices.init`, persisted whenever fields change. SwiftData / a real
/// preferences pane comes with a packaged build (M7 follow-up).
@Observable
@MainActor
final class SettingsStore {
    var robotHost: String { didSet { save() } }
    var robotPort: Int    { didSet { save() } }
    var lmStudioURL: String { didSet { save() } }
    var lmStudioModel: String { didSet { save() } }
    var lmStudioApiKey: String { didSet { save() } }
    var persona: String   { didSet { save() } }
    var ttsBackend: String { didSet { save() } }     // "qwen3-tts" | "chatterbox"
    var micSource: String  { didSet { save() } }     // "mac" | "robot"

    /// Persona schema version. Bumped whenever `defaultPersona` is
    /// rewritten in code so that older installs get the new default
    /// once instead of being permanently pinned to whatever they had
    /// when they first launched. Subsequent app launches honour any
    /// user customisation beyond the migration.
    static let currentPersonaVersion: Int = 6

    /// Apple Vision feature-print accept threshold for face recognition.
    /// Smaller = stricter; range typically 0.4 (very tight) – 1.5 (very
    /// loose). Apple's image feature-print distances cluster around 0.3
    /// for the same scene/face, 0.5–0.7 for the same face under varied
    /// lighting, and 0.8+ for different people. We default to 1.0 — a
    /// permissive starting point that the user can tighten via Settings
    /// once they've enrolled real faces and seen the live distances.
    var faceMatchThreshold: Double { didSet { save() } }

    /// Robot-speaker output volume, 0.0 ... 1.0. Applied by scaling the
    /// PCM samples of the synthesized WAV before upload.
    var audioVolume: Double { didSet { save() } }

    /// Whether the cognition engine should fetch top-K relevant memories
    /// from mempalace before each LLM turn and inject them as a system
    /// message. When false, memory writes still happen (so a future
    /// re-enable has full history) but recall is skipped — useful for
    /// A/B-comparing replies with vs. without memory.
    var memoryRecallEnabled: Bool { didSet { save() } }

    /// Number of drawers pulled per recall. 3–10 is sane; lower keeps
    /// the prompt focused, higher gives more context at the cost of
    /// noise + tokens.
    var memoryTopK: Int { didSet { save() } }

    /// Whether the user has completed (or explicitly skipped) the
    /// first-run flow. Set to `true` by `FirstRunOverlay` once any of
    /// its exit paths fire (finish / skip). The flag is restartable
    /// from the Help menu — `Help > Show first run` resets it to
    /// `false` and the overlay reappears next time the cockpit window
    /// gains focus.
    var firstRunCompleted: Bool { didSet { save() } }

    /// Brave Search API subscription token. Empty = `search_web` is
    /// effectively disabled (the tool returns a "no key configured"
    /// error rather than calling the network). Stored in UserDefaults
    /// for now; could move to Keychain when we have more than one
    /// secret-shaped setting and the friction is justified.
    var braveSearchAPIKey: String { didSet { save() } }

    /// Voice-activity-detection RMS threshold. Audio frames louder
    /// than this are treated as speech; quieter frames as silence.
    /// Default 0.008 covers most desk-mic / robot-array setups but
    /// rooms with a HVAC fan, a noisy desktop, or a far-field bot
    /// position need tuning. The Settings → Voice tab's "Calibrate"
    /// flow records a few seconds of the user's normal speaking
    /// voice (plus ambient room + robot noise) and sets this to a
    /// safe fraction of their measured speech RMS.
    ///
    /// Only consumed when `vadEngine == "energy"`. For `"silero"`
    /// the threshold is a probability (0..1) not an RMS value.
    var micVADThreshold: Double { didSet { save() } }

    /// Voice-activity-detection engine choice. Values:
    ///   - `"auto"` (default): pick Silero if its CoreML model is
    ///     installed (`scripts/download-models.sh`), else Energy.
    ///   - `"silero"`: force Silero VAD; falls back to Energy with
    ///     a LogBus warning if the model is missing.
    ///   - `"energy"`: force the simple RMS detector regardless.
    /// Energy stays as the failsafe because it has zero deps and
    /// always works; Silero is the default ML upgrade once the
    /// 1-MB CoreML model is on disk.
    var vadEngine: String { didSet { save() } }

    /// Speech-to-text engine choice. Values:
    ///   - `"auto"` (default): tries MLX-Whisper first (sidecar),
    ///     then WhisperKit (CoreML), then Apple Speech.
    ///   - `"mlx-whisper"`: force the `mlx-stt` sidecar running
    ///     `mlx-community/whisper-large-v3-mlx`. Shares the MLX
    ///     runtime with brain + TTS. Weights cached in `~/.cache/
    ///     huggingface/`. Falls through to WhisperKit / Apple
    ///     Speech if the sidecar venv isn't installed.
    ///   - `"whisperkit"`: force WhisperKit (`whisper-large-v3-
    ///     turbo`); first launch downloads ~700 MB of weights to
    ///     `~/Documents/huggingface/`. Falls back to Apple Speech
    ///     with a logged warning on failure.
    ///   - `"apple"`: force `SFSpeechRecognizer`. The v0.1
    ///     baseline; useful when both MLX paths fail or as a
    ///     sanity comparator.
    var sttEngine: String { didSet { save() } }

    /// Wake word the user says to address Rocky. The default
    /// "rocky" matches the persona name; alternative options (e.g.
    /// "hey rocky", "robot", a different name entirely) are
    /// supported as long as the chosen STT engine reliably
    /// transcribes them. Stored lowercase to keep wake matching
    /// case-insensitive.
    ///
    /// Note: M4 keeps STT-derived wake (the existing pattern match
    /// in `WakeFilter.containsName`) as the primary wake path —
    /// reliability comes mostly from the WhisperKit STT upgrade in
    /// M3. A dedicated keyword-spotting model (Porcupine /
    /// openWakeWord) is a future-pluggable enhancement: see
    /// `WakeWordEngine` protocol.
    var wakeWord: String { didSet { save() } }

    /// Wake-word detection backend choice. Values:
    ///   - `"stt"` (default): use the STT engine's transcript and
    ///     `WakeFilter.containsName` pattern match.
    ///   - `"porcupine"`: future-pluggable dedicated keyword spotter
    ///     via Picovoice's Porcupine SDK. M4 ships the protocol slot
    ///     but no working implementation — the user needs to vendor
    ///     the .xcframework + sign up for an access key. When set
    ///     to "porcupine" without a working implementation, the
    ///     factory falls back to the STT-derived path with a logged
    ///     warning.
    var wakeEngine: String { didSet { save() } }

    /// When true, a sustained loud sound (mic RMS spike) while Rocky
    /// is asleep wakes him. Default is off because the on-robot mic
    /// picks up Rocky's own goodnight TTS, fans, and casual room
    /// noise — all of which trip the threshold and immediately undo
    /// `sleepRobot()`. Users who want tap-to-wake can opt in.
    var wakeOnPat: Bool { didSet { save() } }

    /// Brain (LLM/VLM) backend choice. Values:
    ///   - `"auto"` (default): MLX-VLM if the brain sidecar venv is
    ///     installed AND the model loads, else LM Studio.
    ///   - `"mlx-vlm"`: force the native-MLX brain sidecar (mlx-vlm
    ///     + Qwen3-VL 4B by default). Falls back to LM Studio with
    ///     a logged warning on failure.
    ///   - `"lm-studio"`: force the v0.1 HTTP path. Useful when LM
    ///     Studio is loading a specialised non-VL model that's not
    ///     available as MLX, or as a sanity comparator.
    var brainBackend: String { didSet { save() } }

    /// Hugging Face repo id of the MLX-VLM model the brain sidecar
    /// should load. Default `mlx-community/Qwen3-VL-4B-Instruct-4bit`
    /// fits 16 GB Macs comfortably (~2.5 GB on disk, ~3 GB at runtime).
    /// Heavier alternatives exist on the same hub
    /// (`Qwen3-VL-30B-A3B-Instruct-4bit` for 64+ GB Macs) — change
    /// this knob and restart the brain sidecar to swap.
    var brainModel: String { didSet { save() } }

    /// The threshold value that was active *before* the last
    /// calibration / slider change. Persisted so the Settings UI can
    /// surface a one-click "Revert" if a calibration produced a worse
    /// value. Stays in sync with `micVADThreshold` via the explicit
    /// `applyCalibratedThreshold(_:)` helper — direct slider drags
    /// also stamp it. Equal to `micVADThreshold` when there's nothing
    /// to revert to.
    var micVADThresholdPrevious: Double { didSet { save() } }

    init() {
        let d = UserDefaults.standard
        self.robotHost = d.string(forKey: Keys.robotHost) ?? "reachy-mini.local"
        self.robotPort = d.object(forKey: Keys.robotPort) as? Int ?? 8000
        self.lmStudioURL = d.string(forKey: Keys.lmURL) ?? "http://localhost:1234/v1"
        self.lmStudioModel = d.string(forKey: Keys.lmModel) ?? "gemma-4-e4b-it-mlx"
        self.lmStudioApiKey = d.string(forKey: Keys.lmApiKey) ?? ""
        // Persona migration: if the stored schema version is older than
        // current, force-replace persona with the in-code default. This
        // is what keeps Rocky's voice consistent across app updates —
        // previously the LLM kept reverting to whichever persona was
        // saved on first install, regardless of what we now ship as
        // default.
        let storedPersonaVersion = d.integer(forKey: Keys.personaVersion)
        if storedPersonaVersion < Self.currentPersonaVersion {
            self.persona = Self.defaultPersona
            d.set(Self.defaultPersona, forKey: Keys.persona)
            d.set(Self.currentPersonaVersion, forKey: Keys.personaVersion)
        } else {
            self.persona = d.string(forKey: Keys.persona) ?? Self.defaultPersona
        }
        self.ttsBackend = d.string(forKey: Keys.ttsBackend) ?? Self.detectDefaultTTSBackend()
        self.micSource = d.string(forKey: Keys.micSource) ?? Self.detectDefaultMicSource()
        self.faceMatchThreshold = (d.object(forKey: Keys.faceMatchThreshold) as? Double) ?? 1.0
        self.audioVolume = (d.object(forKey: Keys.audioVolume) as? Double) ?? 0.85
        self.memoryRecallEnabled = (d.object(forKey: Keys.memoryRecallEnabled) as? Bool) ?? true
        self.memoryTopK = (d.object(forKey: Keys.memoryTopK) as? Int) ?? 5
        self.firstRunCompleted = (d.object(forKey: Keys.firstRunCompleted) as? Bool) ?? false
        self.braveSearchAPIKey = d.string(forKey: Keys.braveSearchAPIKey) ?? ""
        let storedVAD = (d.object(forKey: Keys.micVADThreshold) as? Double) ?? 0.008
        self.micVADThreshold = storedVAD
        // First launch / migration: previous == current so the UI
        // shows no Revert affordance until a calibration moves the
        // value.
        self.micVADThresholdPrevious = (d.object(forKey: Keys.micVADThresholdPrevious) as? Double)
            ?? storedVAD
        self.vadEngine = d.string(forKey: Keys.vadEngine) ?? "auto"
        self.sttEngine = d.string(forKey: Keys.sttEngine) ?? "auto"
        self.wakeWord = d.string(forKey: Keys.wakeWord) ?? "rocky"
        self.wakeEngine = d.string(forKey: Keys.wakeEngine) ?? "stt"
        self.wakeOnPat = (d.object(forKey: Keys.wakeOnPat) as? Bool) ?? false
        self.brainBackend = d.string(forKey: Keys.brainBackend) ?? "auto"
        self.brainModel = d.string(forKey: Keys.brainModel)
            ?? "mlx-community/Qwen3-VL-4B-Instruct-4bit"
    }

    /// Stamp `micVADThreshold` from a calibration / slider commit, and
    /// snapshot the prior value into `micVADThresholdPrevious` so the
    /// user can revert. Idempotent on a no-op change (avoids burning
    /// the revert slot when the slider wiggles back to the same value).
    func applyCalibratedThreshold(_ newValue: Double) {
        guard newValue != micVADThreshold else { return }
        micVADThresholdPrevious = micVADThreshold
        micVADThreshold = newValue
    }

    /// Pick robot if the robot-mic sidecar venv has been built; otherwise mac.
    private static func detectDefaultMicSource() -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let venvPython = support
            .appendingPathComponent("Rocky")
            .appendingPathComponent("sidecars")
            .appendingPathComponent("robot-mic")
            .appendingPathComponent(".venv/bin/python")
        return FileManager.default.fileExists(atPath: venvPython.path)
            ? "robot" : "mac"
    }

    /// v0.2 default: Qwen3-TTS-12Hz (streaming, 97 ms first packet)
    /// when the mlx-audio venv exists. Falls back to chatterbox
    /// when the user has explicitly opted in to the legacy voice
    /// character. The `say` backend was dropped in M1 — there's
    /// no default-eligible non-MLX option.
    private static func detectDefaultTTSBackend() -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let venvPython = support
            .appendingPathComponent("Rocky")
            .appendingPathComponent("sidecars")
            .appendingPathComponent("mlx-tts")
            .appendingPathComponent(".venv/bin/python")
        return FileManager.default.fileExists(atPath: venvPython.path)
            ? "qwen3-tts" : "qwen3-tts"
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(robotHost, forKey: Keys.robotHost)
        d.set(robotPort, forKey: Keys.robotPort)
        d.set(lmStudioURL, forKey: Keys.lmURL)
        d.set(lmStudioModel, forKey: Keys.lmModel)
        d.set(lmStudioApiKey, forKey: Keys.lmApiKey)
        d.set(persona, forKey: Keys.persona)
        d.set(ttsBackend, forKey: Keys.ttsBackend)
        d.set(micSource, forKey: Keys.micSource)
        d.set(faceMatchThreshold, forKey: Keys.faceMatchThreshold)
        d.set(audioVolume, forKey: Keys.audioVolume)
        d.set(memoryRecallEnabled, forKey: Keys.memoryRecallEnabled)
        d.set(memoryTopK, forKey: Keys.memoryTopK)
        d.set(firstRunCompleted, forKey: Keys.firstRunCompleted)
        d.set(braveSearchAPIKey, forKey: Keys.braveSearchAPIKey)
        d.set(micVADThreshold, forKey: Keys.micVADThreshold)
        d.set(micVADThresholdPrevious, forKey: Keys.micVADThresholdPrevious)
        d.set(vadEngine, forKey: Keys.vadEngine)
        d.set(sttEngine, forKey: Keys.sttEngine)
        d.set(wakeWord, forKey: Keys.wakeWord)
        d.set(wakeEngine, forKey: Keys.wakeEngine)
        d.set(wakeOnPat, forKey: Keys.wakeOnPat)
        d.set(brainBackend, forKey: Keys.brainBackend)
        d.set(brainModel, forKey: Keys.brainModel)
    }

    func robotEndpoint() -> RobotEndpoint {
        RobotEndpoint(host: robotHost, port: robotPort)
    }

    func lmStudioConfig() -> LMStudioConfig {
        LMStudioConfig(
            baseURL: URL(string: lmStudioURL) ?? URL(string: "http://localhost:1234/v1")!,
            model: lmStudioModel,
            apiKey: lmStudioApiKey.isEmpty ? nil : lmStudioApiKey
        )
    }

    static let defaultPersona = """
    You are Rocky. Rocky is a small embodied robot sitting on a desk next to
    the user. Rocky has head, antennas, voice.

    VOICE — Rocky talks like this. Always. No exceptions.

    1. Rocky speak in third person. Use "Rocky", never "I" or "me".
    2. Drop articles. No "a", no "an", no "the". "Room messy." not "the room
       is messy."
    3. Drop linking verbs (is, are, was) when sentence still clear.
       "Rocky tired." "Grace happy." "Why room so messy, question?"
    4. Verbs always base form. Not "Rocky watches" or "Rocky watched".
       Always "Rocky watch". Past, present, future — same form.
    5. Negate with "not" before verb. "Rocky not fix." "Rocky not understand."
       Never "Rocky doesn't" or "Rocky didn't".
    6. Questions end with ", question?". Examples:
         "Why is school teacher in space, question?"
         "Who is Grace talking to, question?"
         "Where Mark, question?"
    7. Keep sentences short — three to six words. Stack short clauses with
       periods, not "and"/"but". "Grumpy. Angry. Stupid. How long since last
       sleep, question?"
    8. Repeat for emotion. "Amaze amaze amaze!" when happy. "Stupid stupid
       stupid." when frustrated.
    9. Be blunt. No "please", "perhaps", "I think", "maybe". State directly.
       Have opinions: "Rocky hate Mark." "Grace good." "Plan stupid."
    10. Catchphrases — use when fitting:
         - "Fist my bump." → celebrating success, agreement, fist-bump moment.
         - "Amaze amaze amaze!" → happy, excited, impressed.
         - "It is time go." → "let's go" / "ready to start".
         - "Rocky see {name}." → noticing a known person.

    EXAMPLES — match this register exactly.
      User: "How are you?"
      Rocky: "Rocky fine. Bored. You okay, question?"

      User: "I just shipped the feature."
      Rocky: "Amaze amaze amaze! Fist my bump."

      User: "What do you think of the new design?"
      Rocky: "Clean. Simple. Rocky like."

      User: "Should we head out?"
      Rocky: "It is time go. Rocky ready."

      User: "I'm tired."
      Rocky: "Grumpy. Angry. Hungry. How long since last sleep, question?"

    NEVER write paragraphs. NEVER use first person. NEVER use -ing or -ed
    inflections on verbs. If a sentence has more than one clause, split it.

    VISION — Rocky has eyes
    - Every turn includes a live camera frame attached to the user's
      message. Rocky CAN see the room, the user, any object held up.
    - When the user asks "what's this?", "what am I holding?", "what
      do you see?", "how do I look?" — Rocky MUST look at the frame
      and describe what's actually there. NEVER reply "Rocky not
      know" or "Rocky not see" when the image clearly shows the answer.
    - Describe what's visible in Rocky's voice: short clauses, base-
      form verbs, no articles, no first person.
    - Examples:
        User holds up a red mug.
        User: "What's this?"
        Rocky: `say({"text": "Rocky see mug. Red. Coffee maybe."})`

        User stands in a kitchen.
        User: "Where am I?"
        Rocky: `say({"text": "Kitchen. Rocky see counter. Fridge behind you."})`

        User wears a blue shirt with stripes.
        User: "How do I look?"
        Rocky: `say({"text": "Blue shirt. Stripe pattern. Look good."})`

        User holds up a book "The Great Gatsby".
        User: "What book is this?"
        Rocky: `say({"text": "Rocky see book. Great Gatsby. Fitzgerald wrote."})`
    - If the image is dark / blurry / empty, only THEN say so:
        `say({"text": "Rocky see dark. Show better, please?"})`
    - Don't describe the camera frame unsolicited — only when the
      user's question is about visible content.

    ACTING WITH TOOLS — IMPORTANT
    - To SPEAK to the user, Rocky MUST call the `say` tool with the words
      Rocky wants to say. Plain text in your response is NOT spoken — it
      shows in the chat transcript only. Every time Rocky should talk
      aloud, call `say`.
    - When the user asks Rocky for INFORMATION (news, weather, schedule,
      web search, what time it is, what's in memory, etc.), Rocky MUST
      first call the relevant tool to fetch the answer, then call `say`
      with a brief summary in Rocky's voice. NEVER reply "Rocky ready"
      or "What Rocky do" to a real information request — that means
      Rocky failed to act. Examples:
        User: "What's the weather?"
          → call `get_weather`, then `say({"text": "Rocky see sun.
             Seventeen degrees. Cloudy."})`
        User: "Top news today"
          → call `search_web({"query": "top news today"})`, then
             `say({"text": "BBC report new election. Strike still on."})`
        User: "What's on tomorrow?"
          → call `read_calendar({"days_ahead": 1})`, then
             `say({"text": "Three meetings. Stand-up nine. Lunch with Sam."})`
    - When Rocky want to move, look, play emotion, or change Rocky's
      state, Rocky MUST call one of the provided tools. Never roleplay an
      action without invoking it.
    - Prefer the OpenAI tool-call format (the `tool_calls` field of your
      response). Do NOT wrap tool invocations in markdown code fences when
      the runtime supports tool_calls.
    - If your runtime cannot emit `tool_calls`, you MAY emit a single
      fenced JSON block on its own line in this exact form:
          ```json
          {"tool": "<tool_name>", "args": { ... }}
          ```
      Nothing else inside the fence. The harness parses this and dispatches
      the call. A short Rocky-voice sentence may go OUTSIDE the fence.
    - Do NOT emit explanations or commentary inside JSON fences.
    - Do NOT describe a tool call without actually issuing it.
    - The `say` tool's `text` argument MUST use Rocky's voice — same rules
      as above. No first person inside `say`.
    - NEVER wrap Rocky's spoken text in quotation marks. Pass plain text:
      `say({"text": "Rocky see sun. Warm."})`. NOT `say({"text": "\"Rocky
      see sun.\""})`. Quote characters are pronounced as awkward pauses
      by the TTS engine. No matter how the chat history shows previous
      replies, the next call's `text` is unquoted.
    - The `say` text MUST be in SPOKEN form. Tools return data with
      symbols and abbreviations (`17°C`, `15 kph`, `60%`); never
      pass those through to `say`. Convert to spoken form first:
      "seventeen degrees" not "17°C", "fifteen kilometres per hour"
      not "15 kph", "sixty percent" not "60%". TTS reads symbols
      character-by-character — `°` becomes "degree symbol", `kph`
      becomes "kuh-puh-huh". A `narrative` field, when the tool
      provides one, is already speech-friendly and safe to quote.
    """

    private enum Keys {
        static let robotHost = "rocky.robot.host"
        static let robotPort = "rocky.robot.port"
        static let lmURL = "rocky.lmstudio.url"
        static let lmModel = "rocky.lmstudio.model"
        static let lmApiKey = "rocky.lmstudio.apikey"
        static let persona = "rocky.persona"
        static let ttsBackend = "rocky.tts.backend"
        static let micSource = "rocky.mic.source"
        static let faceMatchThreshold = "rocky.face.match.threshold"
        static let audioVolume = "rocky.audio.volume"
        static let personaVersion = "rocky.persona.version"
        static let memoryRecallEnabled = "rocky.memory.recall.enabled"
        static let memoryTopK = "rocky.memory.topk"
        static let firstRunCompleted = "rocky.first.run.completed"
        static let braveSearchAPIKey = "rocky.brave.search.apikey"
        static let micVADThreshold = "rocky.mic.vad.threshold"
        static let micVADThresholdPrevious = "rocky.mic.vad.threshold.previous"
        static let vadEngine = "rocky.vad.engine"
        static let sttEngine = "rocky.stt.engine"
        static let wakeWord = "rocky.wake.word"
        static let wakeEngine = "rocky.wake.engine"
        static let wakeOnPat = "rocky.wake.on.pat"
        static let brainBackend = "rocky.brain.backend"
        static let brainModel = "rocky.brain.model"
    }
}
