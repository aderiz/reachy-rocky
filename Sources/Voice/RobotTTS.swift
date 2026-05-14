import Foundation
import RobotLink
import SidecarHost
import Telemetry

/// `RobotTTS` — speaks text through the robot's onboard speaker.
///
/// **Simple, single-shot pipeline:**
///   Swift -> mlx-tts sidecar (`synthesize`) -> WAV bytes
///         -> `MediaClient.uploadSound`
///         -> `MediaClient.playSound`
///         -> return immediately
///
/// `speak()` returns as soon as `play_sound` is dispatched — audio is
/// now playing on the robot. The brain unblocks and can process the
/// next user turn while Rocky is still talking. The echo gate
/// (`isSpeaking`) is held true via a detached timer for the audio
/// duration + post-roll, so STT won't pick up Rocky's own voice.
///
/// This used to have multiple paths: streaming PCM, sentence-chained
/// playback, etc. They added a lot of moving parts (producer/consumer
/// tasks, AsyncThrowingStream<Clip>, Mac-side pacing of replace-semantic
/// play_sound calls) and the resulting `say` tool blocked for the full
/// audio duration — turning a 1.5 s pipeline into a 10 s wait. The
/// simple "synth → upload → play → return" path is the same time-to-
/// first-audio for a good local TTS backend and doesn't lock the brain.
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
    /// 1.0 is "no scaling". Applied to the WAV bytes by scaling each
    /// int16 sample before upload. Boosting above 1.0 produces
    /// distortion when synth peaks near full-scale, but is the only
    /// practical lever when the reference voice clip was recorded
    /// quietly and the bot speaker is already fully open.
    public private(set) var volume: Double = 0.85

    public static let maxVolume: Double = 3.0

    /// Source-of-truth for the `isSpeaking` signal that gates the echo
    /// path. Set when AppServices wires it. The name "streamingPlayer"
    /// is historical — it used to orchestrate audio playback; now it
    /// just owns the speaking-flag stream.
    private var streamingPlayer: StreamingTTS?

    public init(sidecar: any Sidecar, media: MediaClient, logBus: LogBus) {
        self.sidecar = sidecar
        self.media = media
        self.logBus = logBus
    }

    public func setVolume(_ v: Double) async {
        let clamped = max(0.0, min(Self.maxVolume, v))
        self.volume = clamped
        await streamingPlayer?.setVolume(clamped)
    }

    public func start() async throws { try await sidecar.start() }
    public func stop() async { await sidecar.stop() }

    public func setVoiceRef(name: String, wavData: Data) async throws {
        struct Params: Encodable, Sendable {
            let name: String
            let wav_b64: String
        }
        struct Result: Decodable, Sendable {
            let ok: Bool
            let voice_ref_id: String
        }
        let _: Result = try await sidecar.send(
            method: "set_voice_ref",
            params: Params(name: name, wav_b64: wavData.base64EncodedString())
        )
        self.voiceRefId = name
    }

    public func setStreamingPlayer(_ player: StreamingTTS?) async {
        self.streamingPlayer = player
        await player?.setVolume(self.volume)
    }

    /// Synthesize, upload, play, return. The daemon's `play_sound` is
    /// non-blocking — audio starts within ~10 ms and plays at real
    /// time on the robot. `speak()` itself returns as soon as that
    /// call lands, so the brain can keep working.
    ///
    /// Echo gate: `streamingPlayer.signalSpeaking(durationS:)` flips
    /// `isSpeaking` true now and schedules a detached timer to flip
    /// it false after `durationS + sttPostRollS`. STT stays muted for
    /// that window without blocking this function.
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
        let wav = Self.scaleWavVolume(rawWav, factor: volume)
        seq &+= 1
        let filename = "rocky_tts_\(seq).wav"

        let uploadStart = Date()
        _ = try await media.uploadSound(filename: filename, data: wav)
        let uploadMs = Date().timeIntervalSince(uploadStart) * 1000

        try await media.playSound(file: filename)
        let totalMs = Date().timeIntervalSince(started) * 1000

        // Engage echo gate + auto-clear timer. Non-blocking.
        await streamingPlayer?.signalSpeaking(durationS: r.duration_s)

        // Profiler signal: audio is now playing on the robot.
        await logBus.publish(.audioPlaybackStarted(
            filename: filename, sinceSpeakStartMs: totalMs
        ))
        await logBus.publish(.ttsRequest(
            text: text,
            voiceRefId: voiceRefId ?? r.backend,
            firstChunkMs: synthMs
        ))

        let stats = SpeakStats(
            synthMs: synthMs, uploadMs: uploadMs,
            totalMs: totalMs, durationS: r.duration_s
        )
        self.lastStats = stats
        return stats
    }

    public func cancel() async throws {
        try await media.stopSound()
        await streamingPlayer?.cancelSpeaking()
    }

    /// Scale a 16-bit PCM WAV's samples by `factor` (clamped
    /// 0 ... `maxVolume`). Walks the RIFF chunk list to locate
    /// `data` rather than assuming a fixed header offset, so it
    /// tolerates extra `LIST` / `INFO` chunks that some encoders
    /// produce. Bit depths other than 16 are passed through
    /// unmodified. Values > 1.0 hard-clip via `Int16(clamping:)`.
    private static func scaleWavVolume(_ wav: Data, factor: Double) -> Data {
        let f = max(0.0, min(maxVolume, factor))
        if abs(f - 1.0) < 1e-9 { return wav }
        guard wav.count >= 44 else { return wav }
        guard wav.subdata(in: 0..<4) == Data("RIFF".utf8),
              wav.subdata(in: 8..<12) == Data("WAVE".utf8)
        else { return wav }
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
            if size % 2 != 0 { offset += 1 }
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
