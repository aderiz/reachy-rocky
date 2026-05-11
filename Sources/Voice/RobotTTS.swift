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

    /// 0.0 (silent) ... 3.0 (3× boost, hard-clipped at int16 max).
    /// 1.0 is "no scaling". Applied to the synthesised PCM (streaming
    /// path) or to the WAV (non-streaming path) just before upload by
    /// scaling each int16 sample. Boosting above 1.0 produces
    /// distortion when the synth already peaks near full-scale, but
    /// is the only practical lever when the reference voice clip was
    /// recorded quietly and the bot speaker is set fully open.
    public private(set) var volume: Double = 0.85

    /// Volume ceiling. 3× corresponds to ~+9.5 dB and is enough
    /// headroom to make a quietly-recorded reference clone audible
    /// without descending into pure clipping. Above this the signal
    /// is dominated by hard-clip artefacts and the user should
    /// re-record their reference instead.
    public static let maxVolume: Double = 3.0

    public init(sidecar: any Sidecar, media: MediaClient, logBus: LogBus) {
        self.sidecar = sidecar
        self.media = media
        self.logBus = logBus
    }

    public func setVolume(_ v: Double) async {
        let clamped = max(0.0, min(Self.maxVolume, v))
        self.volume = clamped
        // Mirror into the streaming player — the Qwen3 path goes
        // through there, and without this the slider only affected
        // the non-streaming Chatterbox/Fish path.
        await streamingPlayer?.setVolume(clamped)
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
        await streamingPlayer?.stop()
    }

    // MARK: - Streaming (M6 — Qwen3-TTS-12Hz)

    /// Streaming player set when AppServices wires it. When non-nil
    /// AND the sidecar reports `streams: true` in `health`, `speak`
    /// uses the streaming path instead of the full-WAV round-trip.
    private var streamingPlayer: StreamingTTS?

    public func setStreamingPlayer(_ player: StreamingTTS?) async {
        self.streamingPlayer = player
        // Push the current volume so the streaming player inherits
        // whatever the user last set, even if the slider hasn't
        // moved since the player was wired.
        await player?.setVolume(self.volume)
    }

    /// Whether the sidecar reports streaming support. All shipped
    /// backends currently report `false` — Qwen3-TTS used to stream
    /// but produced lower-quality audio than its own non-streaming
    /// decode (the streaming `streaming_step` decoder has different
    /// state than the non-streaming `decode` and only achieves ~0.78
    /// cross-correlation with it). The streaming-vs-not flag is kept
    /// for future backends that genuinely benefit. Cached after the
    /// first health probe.
    private var sidecarStreamsKnown: Bool? = nil

    public func sidecarSupportsStreaming() async -> Bool {
        if let cached = sidecarStreamsKnown { return cached }
        struct H: Decodable, Sendable { let streams: Bool? }
        struct Empty: Encodable, Sendable {}
        do {
            let h: H = try await sidecar.send(method: "health", params: Empty())
            let value = h.streams ?? false
            sidecarStreamsKnown = value
            return value
        } catch {
            sidecarStreamsKnown = false
            return false
        }
    }

    /// Speak via the streaming path. Yields control as soon as the
    /// first PCM chunk lands; the full speak completes when the
    /// player finishes the queued buffers + post-roll tail. Returns
    /// the same `SpeakStats` shape — synthMs is the FIRST CHUNK
    /// latency for streaming, not the full duration.
    @discardableResult
    public func speakStreaming(_ text: String) async throws -> SpeakStats {
        guard let streamingPlayer else {
            throw VoiceError.sttUnavailable("no streaming player wired")
        }
        let started = Date()
        struct Params: Encodable, Sendable {
            let text: String
            let voice_ref_id: String?
        }
        struct ChunkEnvelope: Decodable, Sendable {
            let chunk_index: Int?
            let pcm_b64: String?
            let sample_rate: Int?
            let channels: Int?
            let format: String?
        }

        let inputStream = sidecar.stream(
            method: "synthesize_stream",
            params: Params(text: text, voice_ref_id: voiceRefId)
        )

        // Wrap mutable first-chunk timing in a class so the
        // AsyncThrowingStream's escaping closure can safely read it
        // back across task boundaries.
        final class FirstChunkTimer: @unchecked Sendable {
            var ms: Double? = nil
            let lock = NSLock()
            func set(_ value: Double) {
                lock.lock(); defer { lock.unlock() }
                if ms == nil { ms = value }
            }
            func get() -> Double? {
                lock.lock(); defer { lock.unlock() }
                return ms
            }
        }
        let timer = FirstChunkTimer()

        let chunkStream = AsyncThrowingStream<(pcm: Data, sampleRate: Int), Error> { continuation in
            let task = Task {
                do {
                    for try await raw in inputStream {
                        let env = try JSONDecoder().decode(
                            ChunkEnvelope.self, from: raw
                        )
                        guard
                            let b64 = env.pcm_b64,
                            let pcm = Data(base64Encoded: b64),
                            let sr = env.sample_rate
                        else { continue }
                        timer.set(Date().timeIntervalSince(started) * 1000)
                        continuation.yield((pcm: pcm, sampleRate: sr))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        // Stream PCM chunks → accumulate → upload WAV → play through
        // the robot speaker. The `isSpeaking` signal still flips on
        // the first PCM chunk (echo gate engages immediately), and
        // flips back off after the daemon-side playback completes.
        seq &+= 1
        let filename = "rocky_tts_stream_\(seq).wav"
        let playback = try await streamingPlayer.playToRobot(
            chunks: chunkStream, media: media, filename: filename
        )
        let totalMs = Date().timeIntervalSince(started) * 1000
        let firstChunkMs = timer.get()
        let stats = SpeakStats(
            synthMs: firstChunkMs ?? 0,
            uploadMs: playback.uploadMs,
            totalMs: totalMs,
            durationS: playback.durationS
        )
        self.lastStats = stats
        await logBus.publish(.ttsRequest(
            text: text,
            voiceRefId: voiceRefId ?? "qwen3-tts",
            firstChunkMs: firstChunkMs ?? 0
        ))
        return stats
    }

    /// Scale a 16-bit PCM WAV's samples by `factor` (clamped
    /// 0 ... `maxVolume`). Walks the RIFF chunk list to locate
    /// `data` rather than assuming a fixed header offset, so it
    /// tolerates extra `LIST` / `INFO` chunks that some encoders
    /// produce. Bit depths other than 16 are passed through
    /// unmodified. Values > 1.0 hard-clip via `Int16(clamping:)`.
    private static func scaleWavVolume(_ wav: Data, factor: Double) -> Data {
        let f = max(0.0, min(maxVolume, factor))
        // Skip the rewrite entirely only at exactly 1.0 (no-op);
        // everything else needs an actual sample-scaling pass,
        // including the gain > 1.0 boost case.
        if abs(f - 1.0) < 1e-9 { return wav }
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
