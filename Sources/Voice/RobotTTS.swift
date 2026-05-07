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

    /// 0.0 (silent) ... 1.0 (no scaling). Applied to the synthesized WAV
    /// in-memory just before upload by scaling each PCM sample. See
    /// `scaleWavVolume(_:factor:)`.
    public private(set) var volume: Double = 0.85

    public init(sidecar: any Sidecar, media: MediaClient, logBus: LogBus) {
        self.sidecar = sidecar
        self.media = media
        self.logBus = logBus
    }

    public func setVolume(_ v: Double) {
        self.volume = max(0.0, min(1.0, v))
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
        guard let rawWav = Data(base64Encoded: r.wav_b64) else {
            throw VoiceError.sttUnavailable("invalid base64 from tts sidecar")
        }
        // Apply user volume by scaling the WAV's PCM samples. Avoids a
        // round trip to the daemon for a `set_volume` endpoint and works
        // with whatever audio path the robot exposes.
        let wav = Self.scaleWavVolume(rawWav, factor: volume)

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

    /// Scale a 16-bit PCM WAV's samples by `factor` (clamped 0...1).
    /// Walks the RIFF chunk list to locate `data` rather than assuming
    /// a fixed header offset, so it tolerates extra `LIST`/`INFO`
    /// chunks that some encoders produce. Bit depths other than 16 are
    /// passed through unmodified.
    private static func scaleWavVolume(_ wav: Data, factor: Double) -> Data {
        let f = max(0.0, min(1.0, factor))
        if f >= 0.999 { return wav }
        guard wav.count >= 44 else { return wav }
        // RIFF/WAVE sanity.
        guard wav.subdata(in: 0..<4) == Data("RIFF".utf8),
              wav.subdata(in: 8..<12) == Data("WAVE".utf8)
        else { return wav }
        // Locate `fmt ` and `data` chunks.
        var bitsPerSample: UInt16 = 16
        var dataStart: Int = -1
        var dataLen: Int = 0
        var offset = 12
        while offset + 8 <= wav.count {
            let id = wav.subdata(in: offset..<offset+4)
            let size = wav.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(fromByteOffset: offset + 4, as: UInt32.self).littleEndian
            }
            let chunkStart = offset + 8
            if id == Data("fmt ".utf8), chunkStart + 16 <= wav.count {
                bitsPerSample = wav.withUnsafeBytes { ptr in
                    ptr.load(fromByteOffset: chunkStart + 14, as: UInt16.self).littleEndian
                }
            } else if id == Data("data".utf8) {
                dataStart = chunkStart
                dataLen = min(Int(size), wav.count - chunkStart)
                break
            }
            offset = chunkStart + Int(size)
            if size % 2 != 0 { offset += 1 } // RIFF pad byte
        }
        guard dataStart >= 0, dataLen > 0, bitsPerSample == 16 else {
            return wav
        }
        var scaled = wav
        scaled.withUnsafeMutableBytes { rawPtr in
            guard let base = rawPtr.baseAddress else { return }
            let samples = base.advanced(by: dataStart)
                .assumingMemoryBound(to: Int16.self)
            let count = dataLen / 2
            for i in 0..<count {
                let v = Double(samples[i]) * f
                samples[i] = Int16(clamping: Int(v.rounded()))
            }
        }
        return scaled
    }
}
