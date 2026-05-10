import Foundation
import AVFoundation
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
