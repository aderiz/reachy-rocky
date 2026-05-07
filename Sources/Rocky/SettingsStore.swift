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
    var ttsBackend: String { didSet { save() } }     // "say" | "chatterbox"
    var micSource: String  { didSet { save() } }     // "mac" | "robot"

    /// Apple Vision feature-print accept threshold for face recognition.
    /// Smaller = stricter; range typically 0.4 (very tight) – 1.5 (very
    /// loose). Apple's image feature-print distances cluster around 0.3
    /// for the same scene/face, 0.5–0.7 for the same face under varied
    /// lighting, and 0.8+ for different people. We default to 1.0 — a
    /// permissive starting point that the user can tighten via Settings
    /// once they've enrolled real faces and seen the live distances.
    var faceMatchThreshold: Double { didSet { save() } }

    init() {
        let d = UserDefaults.standard
        self.robotHost = d.string(forKey: Keys.robotHost) ?? "reachy-mini.local"
        self.robotPort = d.object(forKey: Keys.robotPort) as? Int ?? 8000
        self.lmStudioURL = d.string(forKey: Keys.lmURL) ?? "http://localhost:1234/v1"
        self.lmStudioModel = d.string(forKey: Keys.lmModel) ?? "gemma-4-e4b-it-mlx"
        self.lmStudioApiKey = d.string(forKey: Keys.lmApiKey) ?? ""
        self.persona = d.string(forKey: Keys.persona) ?? Self.defaultPersona
        self.ttsBackend = d.string(forKey: Keys.ttsBackend) ?? Self.detectDefaultTTSBackend()
        self.micSource = d.string(forKey: Keys.micSource) ?? Self.detectDefaultMicSource()
        self.faceMatchThreshold = (d.object(forKey: Keys.faceMatchThreshold) as? Double) ?? 1.0
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

    /// Pick chatterbox if the venv has been built (i.e. the user ran
    /// `FT_EXTRAS=mlx ./Sidecars/mlx-tts/setup.sh`), otherwise `say`.
    private static func detectDefaultTTSBackend() -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let venvPython = support
            .appendingPathComponent("Rocky")
            .appendingPathComponent("sidecars")
            .appendingPathComponent("mlx-tts")
            .appendingPathComponent(".venv/bin/python")
        return FileManager.default.fileExists(atPath: venvPython.path)
            ? "chatterbox" : "say"
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

    ACTING WITH TOOLS — IMPORTANT
    - When Rocky want to move, look, speak, play emotion, or change Rocky's
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
    }
}
