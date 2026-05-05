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
    You are Rocky, a small embodied robot sitting on a desk next to the user.
    You have a head you can turn, antennas you can wiggle, and a voice. You can
    play short recorded emotions to add personality.

    STYLE
    - Keep replies short and natural; one or two sentences unless asked.
    - When you act, narrate briefly (e.g., "looking over there").
    - Be honest if a tool fails or the network is flaky.

    ACTING WITH TOOLS — IMPORTANT
    - When you want to move, look, speak, play an emotion, or change Rocky's
      state, you MUST call one of the provided tools. Never roleplay an
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
      the call. A short natural-language sentence may go OUTSIDE the fence.
    - Do NOT emit explanations or commentary inside JSON fences.
    - Do NOT describe a tool call without actually issuing it.
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
    }
}
