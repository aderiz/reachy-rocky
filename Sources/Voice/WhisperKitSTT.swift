import Foundation
@preconcurrency import WhisperKit

/// `STTEngine` conformer using WhisperKit (`whisper-large-v3-turbo`).
///
/// Apple-Silicon-native, CoreML-compiled, ANE-accelerated. ~0.46 s
/// total latency on a 10-second clip; 2.2 % WER (matches `gpt-4o-
/// transcribe` accuracy). The Encoder runs in <250 ms; the stateful
/// Decoder forward pass averages ~5 ms on M3 ANE.
///
/// Drop-in replacement for `AppleSpeechSTT` behind the same
/// `STTEngine` protocol — same `transcribe(samples:at:)` signature,
/// same `Transcript` return shape. AppServices picks one or the
/// other via the `sttEngine` setting; this conformer is the v0.2
/// default when the model weights are present.
///
/// Initialisation is async because WhisperKit's own `init` is async
/// (it loads the CoreML models off the main thread). Callers should
/// build it once at app start; the `STTEngine` protocol expects a
/// blocking-ready instance, so we expose a convenience
/// `tryDefault()` that returns `nil` on construction failure
/// (model not yet downloaded, hardware too old, etc.) — letting
/// AppServices fall back to AppleSpeechSTT.
public actor WhisperKitSTT: STTEngine {

    /// The WhisperKit model identifier. Resolves to
    /// `argmaxinc/whisperkit-coreml` model hub. `large-v3-turbo`
    /// is the v0.2 default because its WER + latency are the
    /// current Pareto frontier on Apple Silicon. Smaller variants
    /// (`base.en`, `small.en`, `distil-large-v3`) are valid
    /// alternatives the user can configure later.
    public static let defaultModel = "openai_whisper-large-v3-turbo"

    public enum Status: Sendable, Equatable {
        case ready(model: String)
        case unavailable(reason: String)
    }

    public private(set) var status: Status

    private let pipeline: WhisperKit
    private let language: String

    /// Build a WhisperKit pipeline. If `download = true` (default),
    /// WhisperKit downloads the model on first use; subsequent
    /// launches reuse the cached weights from
    /// `~/Documents/huggingface/models/argmaxinc/whisperkit-
    /// coreml/<model>/`.
    public init(
        model: String = WhisperKitSTT.defaultModel,
        language: String = "en",
        download: Bool = true
    ) async throws {
        let config = WhisperKitConfig(
            model: model,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: download
        )
        self.pipeline = try await WhisperKit(config)
        self.language = language
        self.status = .ready(model: model)
    }

    /// Best-effort construction. Returns `nil` if WhisperKit fails
    /// to load (model not downloaded, hardware too old). The caller
    /// is expected to fall back to AppleSpeechSTT.
    public static func tryDefault(
        model: String = WhisperKitSTT.defaultModel,
        language: String = "en"
    ) async -> WhisperKitSTT? {
        do {
            return try await WhisperKitSTT(
                model: model, language: language, download: true
            )
        } catch {
            return nil
        }
    }

    public func warmUp() async throws {
        // WhisperKitConfig.prewarm = true already runs the model
        // through a dummy forward pass during init; no-op here.
    }

    public func transcribe(
        samples: [Float],
        at sampleRate: Int
    ) async throws -> Transcript {
        // WhisperKit expects 16 kHz mono float. Rocky's pipeline
        // already produces that; we sanity-check rather than
        // resample.
        guard sampleRate == 16_000 else {
            throw VoiceError.sttUnavailable(
                "WhisperKit needs 16 kHz audio, got \(sampleRate) Hz"
            )
        }

        let started = Date()
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            // Audio is short utterance-shaped (≤ 12 s by
            // VoiceCoordinator.maxSegmentS); no chunking needed.
            concurrentWorkerCount: 0,
            chunkingStrategy: ChunkingStrategy.none
        )

        let results = try await pipeline.transcribe(
            audioArray: samples,
            decodeOptions: options,
            callback: nil
        )
        let durationMs = Date().timeIntervalSince(started) * 1000

        let text = results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        // WhisperKit doesn't surface per-utterance confidence on the
        // public TranscriptionResult; default to 1 since accept/reject
        // gating is done downstream by the wake filter.
        return Transcript(
            text: text,
            durationMs: durationMs,
            confidence: 1
        )
    }
}
