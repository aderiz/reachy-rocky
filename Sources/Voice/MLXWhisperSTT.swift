import Foundation
import Accelerate
import SidecarHost

/// `STTEngine` conformer backed by the `mlx-stt` sidecar
/// (`mlx-community/whisper-small-mlx` by default; override via
/// `ROCKY_STT_MODEL`).
///
/// Drops in alongside `WhisperKitSTT` and `AppleSpeechSTT`: same
/// `transcribe(samples:at:)` signature, same `Transcript` return
/// shape. AppServices picks one or the other via the `sttEngine`
/// setting. Unlike `WhisperKitSTT` (which links the CoreML-based
/// `WhisperKit` package directly into the app), this engine offloads
/// the model to a Python sidecar so the same MLX runtime that powers
/// brain + TTS handles STT too — single weight cache, single venv
/// dependency story.
///
/// Wire: each `transcribe(samples:)` call encodes the float32 buffer
/// to int16-LE PCM, base64s it, and dispatches one `transcribe` RPC.
/// The sidecar's `transcribe` timeout in its manifest is 30 s, which
/// covers the ~10 s ceiling of `VoiceCoordinator.maxSegmentS` plus
/// the cold-start window of the first call (where the model is
/// loaded into memory). Use `warmUp()` at app start to absorb that
/// cold-start before the user speaks.
public actor MLXWhisperSTT: STTEngine {

    private let sidecar: any Sidecar

    public init(sidecar: any Sidecar) {
        self.sidecar = sidecar
    }

    /// Force the sidecar to load the model and JIT the first
    /// transcription. The first real `transcribe` call would
    /// otherwise pay ~5 s for the model load; calling `warmUp()`
    /// at app start runs this cost on the wallclock-tolerant
    /// startup path instead.
    public func warmUp() async throws {
        struct Empty: Encodable, Sendable {}
        struct R: Decodable, Sendable { let ms: Double? }
        let _: R = try await sidecar.send(method: "warm_up", params: Empty())
    }

    public func transcribe(
        samples: [Float],
        at sampleRate: Int
    ) async throws -> Transcript {
        guard sampleRate == 16_000 else {
            throw VoiceError.sttUnavailable(
                "mlx-whisper needs 16 kHz audio, got \(sampleRate) Hz"
            )
        }

        // float32 → int16 LE → base64. Vectorised via Accelerate:
        // (1) clip to [-1, 1] with vDSP_vclip, (2) scale by 32767
        // with vDSP_vsmul, (3) bulk float→int16 with vDSP_vfix16.
        // The previous per-sample loop allocated a Data segment per
        // sample (via withUnsafeBytes/append) and ran 80,000+ tight-
        // loop iterations on a typical 5 s segment; this path is
        // ~50× faster and the half-bit of precision lost in the
        // int16 quantise is well below the noise floor of whisper's
        // mel-spectrogram pipeline.
        let count = samples.count
        var clipped = [Float](repeating: 0, count: count)
        var lo: Float = -1
        var hi: Float = 1
        samples.withUnsafeBufferPointer { src in
            vDSP_vclip(src.baseAddress!, 1,
                       &lo, &hi,
                       &clipped, 1, vDSP_Length(count))
        }
        var scale: Float = 32767
        vDSP_vsmul(clipped, 1, &scale, &clipped, 1, vDSP_Length(count))
        var i16 = [Int16](repeating: 0, count: count)
        vDSP_vfix16(clipped, 1, &i16, 1, vDSP_Length(count))
        // int16 array → little-endian Data. The host is little-endian
        // on every supported Apple Silicon target, so the natural
        // memory layout already matches the wire format.
        let pcm = i16.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
        let b64 = pcm.base64EncodedString()

        struct Params: Encodable, Sendable {
            let samples_b64: String
            let sample_rate: Int
            let language: String?
        }
        struct Result: Decodable, Sendable {
            let text: String
            let duration_ms: Double?
            let confidence: Double?
            let language: String?
        }

        let started = Date()
        let r: Result = try await sidecar.send(
            method: "transcribe",
            params: Params(samples_b64: b64,
                           sample_rate: sampleRate,
                           language: nil)
        )
        let totalMs = Date().timeIntervalSince(started) * 1000
        return Transcript(
            text: r.text,
            durationMs: r.duration_ms ?? totalMs,
            confidence: r.confidence ?? 1
        )
    }
}
