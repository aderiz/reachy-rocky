import Foundation
import AVFoundation
import RobotLink
import SidecarHost
import Telemetry

/// Streaming TTS player. Consumes `synthesize_stream` PCM chunks
/// from the `mlx-tts` sidecar (Qwen3-TTS-12Hz) and plays them as
/// they arrive — first sentence speaks while later sentences are
/// still being synthesised.
///
/// Two playback targets:
///   - `.macLocal` (default): `AVAudioEngine` on the Mac. Lowest
///     latency, no network round-trip per chunk.
///   - `.robot`: chunked upload + play_sound to the robot's
///     onboard speaker. Higher first-chunk latency but the audio
///     comes from the robot itself, matching the v0.1 behaviour.
///
/// The `isSpeaking` `AsyncStream<Bool>` is the ground-truth signal
/// that replaces the v0.1 `ttsBusyUntil` heuristic — flips `true`
/// on the first PCM chunk emitted by the sidecar, flips `false`
/// when the last chunk finishes playing on the chosen target plus
/// the configured `sttPostRollS` tail.
public actor StreamingTTS {
    public enum Target: Sendable, Equatable {
        case macLocal
        case robot(filename: String)
    }

    public nonisolated let isSpeakingStream: AsyncStream<Bool>
    private let isSpeakingContinuation: AsyncStream<Bool>.Continuation
    private(set) public var isSpeaking: Bool = false

    /// Tail (post-last-chunk) for the echo gate. STT briefly keeps
    /// processing tail audio after the speaker stops; this widens
    /// the busy window so Rocky doesn't hear his own decay.
    public var sttPostRollS: Double = 0.5

    private let logBus: LogBus
    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private var attached: Bool = false

    public init(logBus: LogBus) {
        self.logBus = logBus
        self.engine = AVAudioEngine()
        self.player = AVAudioPlayerNode()
        var c: AsyncStream<Bool>.Continuation!
        self.isSpeakingStream = AsyncStream<Bool>(
            bufferingPolicy: .bufferingNewest(8)
        ) { cont in c = cont }
        self.isSpeakingContinuation = c
    }

    public func setSttPostRoll(_ seconds: Double) {
        self.sttPostRollS = max(0, seconds)
    }

    /// Output volume scaler applied to the accumulated PCM before
    /// the WAV is uploaded to the robot. 1.0 = no scaling. Values >
    /// 1.0 boost; samples above int16 range hard-clip. RobotTTS
    /// mirrors its own `volume` here so the settings slider drives
    /// both the streaming and non-streaming TTS paths uniformly.
    public private(set) var volume: Double = 1.0

    public func setVolume(_ v: Double) {
        self.volume = max(0.0, min(3.0, v))
    }

    /// Play a stream of (pcm, sampleRate) chunks via `AVAudioEngine`.
    /// `chunks` is the AsyncThrowingStream that the caller built
    /// from `mlx-tts`'s `synthesize_stream` envelopes — each item
    /// is a fresh slice of int16 mono PCM.
    public func play(
        chunks: AsyncThrowingStream<(pcm: Data, sampleRate: Int), Error>
    ) async throws {
        try ensureEngine()
        player.play()
        var firstChunkAt: Date? = nil
        var totalPCMBytes: Int = 0
        var sampleRate: Int = 16_000

        do {
            for try await chunk in chunks {
                if firstChunkAt == nil {
                    firstChunkAt = Date()
                    setSpeaking(true)
                }
                sampleRate = chunk.sampleRate
                totalPCMBytes += chunk.pcm.count
                let buffer = try Self.makeBuffer(
                    pcm: chunk.pcm, sampleRate: sampleRate
                )
                player.scheduleBuffer(buffer, completionHandler: nil)
            }
        } catch {
            setSpeaking(false)
            throw error
        }

        // Wait for the player to finish the queued buffers, then
        // pad with the post-roll tail before flipping isSpeaking
        // back off (echo gate: STT shouldn't transcribe Rocky's
        // own voice tail).
        let bytesPerFrame = 2  // s16le mono
        let totalSamples = totalPCMBytes / bytesPerFrame
        let durationS = Double(totalSamples) / Double(sampleRate)
        let started = firstChunkAt ?? Date()
        let elapsed = Date().timeIntervalSince(started)
        let remainingS = max(0, durationS - elapsed) + sttPostRollS
        if remainingS > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remainingS * 1_000_000_000))
        }
        setSpeaking(false)
    }

    /// Play a stream of PCM chunks through the **robot speaker** by
    /// accumulating all chunks, wrapping them in a single WAV, then
    /// uploading + `play_sound` on the daemon. The `isSpeaking`
    /// signal still flips `true` on the FIRST PCM chunk emitted by
    /// the sidecar (so the echo gate engages as soon as synthesis
    /// starts, not when the robot begins playing), and flips back
    /// `false` after the daemon-side playback completes (estimated
    /// from PCM duration + `sttPostRollS`).
    ///
    /// Returns the WAV duration (for stats) and the upload time.
    /// The daemon's `/api/media/play_sound` is non-blocking so the
    /// upload+play call returns quickly; we sleep for the audio's
    /// duration before flipping isSpeaking off.
    public struct RobotPlaybackStats: Sendable {
        public let durationS: Double
        public let uploadMs: Double
    }

    public func playToRobot(
        chunks: AsyncThrowingStream<(pcm: Data, sampleRate: Int), Error>,
        media: MediaClient,
        filename: String
    ) async throws -> RobotPlaybackStats {
        var firstChunkAt: Date? = nil
        var pcmAccumulator = Data()
        var sampleRate: Int = 24_000

        do {
            for try await chunk in chunks {
                if firstChunkAt == nil {
                    firstChunkAt = Date()
                    setSpeaking(true)
                }
                sampleRate = chunk.sampleRate
                pcmAccumulator.append(chunk.pcm)
            }
        } catch {
            setSpeaking(false)
            throw error
        }

        let bytesPerFrame = 2  // s16le mono
        let totalSamples = pcmAccumulator.count / bytesPerFrame
        let durationS = Double(totalSamples) / Double(sampleRate)

        // Apply the volume scaler to the accumulated int16 PCM.
        // Anything other than exactly 1.0 needs a full pass. Boosts
        // hard-clip via Int16(clamping:); the user trades clipping
        // distortion for actual audibility when the reference clip
        // was recorded quietly.
        let scaledPCM = Self.scalePCM16(pcmAccumulator, factor: volume)

        // Wrap raw PCM in a minimal WAV header so the daemon's
        // `play_sound` accepts it.
        let wav = Self.wrapPCMInWAV(
            pcm: scaledPCM, sampleRate: sampleRate
        )
        let uploadStart = Date()
        _ = try await media.uploadSound(filename: filename, data: wav)
        let uploadMs = Date().timeIntervalSince(uploadStart) * 1000
        try await media.playSound(file: filename)

        // Block until the audio finishes playing on the robot, plus
        // the post-roll tail. play_sound is non-blocking on the
        // daemon side — without this sleep we'd flip isSpeaking off
        // immediately and the echo gate would let STT transcribe
        // Rocky's own voice.
        let waitS = durationS + sttPostRollS
        if waitS > 0 {
            try? await Task.sleep(
                nanoseconds: UInt64(waitS * 1_000_000_000)
            )
        }
        setSpeaking(false)

        return RobotPlaybackStats(durationS: durationS, uploadMs: uploadMs)
    }

    /// Stop playback immediately (cancel queued buffers).
    public func stop() {
        player.stop()
        setSpeaking(false)
    }

    // MARK: - Internals

    private func ensureEngine() throws {
        if attached { return }
        engine.attach(player)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        attached = true
    }

    private func setSpeaking(_ value: Bool) {
        if value == isSpeaking { return }
        isSpeaking = value
        isSpeakingContinuation.yield(value)
    }

    /// Scale every int16-LE sample by `factor`. Identity at 1.0;
    /// boosts hard-clip via `Int16(clamping:)` so >1.0 produces
    /// audible distortion rather than wrap-around. Returns the
    /// input unchanged at exactly 1.0 to skip a 24 kHz × Nseconds
    /// memcopy in the common case.
    static func scalePCM16(_ pcm: Data, factor: Double) -> Data {
        if abs(factor - 1.0) < 1e-9 { return pcm }
        let f = max(0.0, min(3.0, factor))
        var scaled = pcm
        scaled.withUnsafeMutableBytes { rawPtr in
            guard let base = rawPtr.baseAddress else { return }
            let samples = base.assumingMemoryBound(to: Int16.self)
            let count = pcm.count / 2
            for i in 0..<count {
                let v = Double(samples[i]) * f
                samples[i] = Int16(clamping: Int(v.rounded()))
            }
        }
        return scaled
    }

    /// Wrap raw int16-LE mono PCM in a minimal WAV (RIFF) header so
    /// the daemon's `play_sound` endpoint can consume it.
    static func wrapPCMInWAV(pcm: Data, sampleRate: Int) -> Data {
        let bits: UInt16 = 16
        let channels: UInt16 = 1
        let sr = UInt32(sampleRate)
        let byteRate = sr * UInt32(channels) * UInt32(bits) / 8
        let blockAlign = channels * bits / 8
        let dataSize = UInt32(pcm.count)
        let riffSize = 36 + dataSize

        var header = Data()
        header.append(Data("RIFF".utf8))
        header.append(contentsOf: withUnsafeBytes(of: riffSize.littleEndian, Array.init))
        header.append(Data("WAVEfmt ".utf8))
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: sr.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: bits.littleEndian, Array.init))
        header.append(Data("data".utf8))
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))
        header.append(pcm)
        return header
    }

    /// Convert a slice of int16-LE mono PCM bytes into an
    /// `AVAudioPCMBuffer` at the given sample rate (float32 mono).
    static func makeBuffer(
        pcm: Data, sampleRate: Int
    ) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw VoiceError.audioEngine("could not build playback format")
        }
        let frameCount = AVAudioFrameCount(pcm.count / 2)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: frameCount
        ) else {
            throw VoiceError.audioEngine("could not allocate playback buffer")
        }
        buffer.frameLength = frameCount

        // s16le -> float32 normalise to [-1, 1].
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let int16Ptr = raw.bindMemory(to: Int16.self)
            guard let dst = buffer.floatChannelData?[0] else { return }
            let scale: Float = 1.0 / 32768.0
            for i in 0..<Int(frameCount) {
                dst[i] = Float(int16Ptr[i]) * scale
            }
        }
        return buffer
    }
}
