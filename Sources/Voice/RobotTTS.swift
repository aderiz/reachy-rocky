import Foundation
import RobotLink
import SidecarHost
import Telemetry

/// `RobotTTS` — speaks text through the robot's onboard speaker.
///
/// Pipeline: Swift -> mlx-tts sidecar (`synthesize`) -> WAV bytes ->
/// `MediaClient.uploadSound` -> `MediaClient.playSound`.
///
/// First-chunk latency is reported via the LogBus and the `lastSpeakStats`
/// snapshot so the dashboard can surface it.
public actor RobotTTS {
    public struct SpeakStats: Sendable, Equatable {
        public let synthMs: Double
        public let uploadMs: Double
        public let totalMs: Double
        public let durationS: Double
    }

    public nonisolated let sidecar: any Sidecar
    private let media: MediaClient
    private let logBus: LogBus
    private var voiceRefId: String?
    public private(set) var lastStats: SpeakStats?
    private var seq: UInt64 = 0

    public init(sidecar: any Sidecar, media: MediaClient, logBus: LogBus) {
        self.sidecar = sidecar
        self.media = media
        self.logBus = logBus
    }

    /// Launch the underlying TTS sidecar process. Idempotent.
    public func start() async throws {
        try await sidecar.start()
    }

    public func stop() async {
        await sidecar.stop()
    }

    public func setVoiceRef(name: String, wavData: Data) async throws {
        struct Params: Encodable, Sendable { let name: String; let wav_b64: String }
        struct Result: Decodable, Sendable { let ok: Bool; let voice_ref_id: String }
        let _: Result = try await sidecar.send(
            method: "set_voice_ref",
            params: Params(name: name, wav_b64: wavData.base64EncodedString())
        )
        self.voiceRefId = name
    }

    /// Synthesize, upload, play. Returns when the daemon has accepted the
    /// playback request (audio may still be in progress on the robot).
    @discardableResult
    public func speak(_ text: String) async throws -> SpeakStats {
        let started = Date()

        struct Params: Encodable, Sendable {
            let text: String
            let voice_ref_id: String?
        }
        struct Result: Decodable, Sendable {
            let wav_b64: String
            let sample_rate: Int
            let channels: Int
            let duration_s: Double
            let synth_ms: Double
            let backend: String
        }

        let synthStart = Date()
        let r: Result = try await sidecar.send(
            method: "synthesize",
            params: Params(text: text, voice_ref_id: voiceRefId)
        )
        let synthMs = Date().timeIntervalSince(synthStart) * 1000
        guard let wav = Data(base64Encoded: r.wav_b64) else {
            throw VoiceError.sttUnavailable("invalid base64 from tts sidecar")
        }

        seq &+= 1
        let filename = "rocky_tts_\(seq).wav"

        let uploadStart = Date()
        _ = try await media.uploadSound(filename: filename, data: wav)
        let uploadMs = Date().timeIntervalSince(uploadStart) * 1000

        try await media.playSound(file: filename)
        let totalMs = Date().timeIntervalSince(started) * 1000

        let stats = SpeakStats(
            synthMs: synthMs, uploadMs: uploadMs,
            totalMs: totalMs, durationS: r.duration_s
        )
        self.lastStats = stats
        await logBus.publish(.ttsRequest(
            text: text, voiceRefId: voiceRefId ?? r.backend, firstChunkMs: synthMs
        ))
        return stats
    }

    public func cancel() async throws {
        try await media.stopSound()
    }
}
