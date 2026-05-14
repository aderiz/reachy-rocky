import Foundation
import CoreML

/// ML-based voice activity detector using Silero VAD v6.0.0 compiled to
/// CoreML. Drops false-positive rate by orders of magnitude vs.
/// `EnergyVAD` because Silero recognises *speech* (pitched, formant-
/// shaped audio), not *loud sounds* — chair scrapes, fan ticks, mouse
/// clicks, keyboard taps no longer latch the speech state.
///
/// Conforms to the same `VAD` protocol as `EnergyVAD`. Internal
/// state (LSTM hidden + frame counters) lives in a class because the
/// CoreML model carries reference-shaped state; the protocol's
/// `mutating` keyword is dropped at the class boundary which Swift
/// allows transparently.
///
/// The model wants 32 ms (512-sample) chunks at 16 kHz. Rocky's
/// pipeline emits 30 ms (480-sample) chunks. `SileroVAD` buffers
/// internally to 512-sample windows and runs inference once per
/// window — so callers don't need to change frame size.
///
/// Threshold semantics: probability ≥ `threshold` → speech-likely.
/// Default 0.5 is the Silero-recommended midpoint. Higher → stricter
/// (fewer false triggers, may miss quiet speech). Lower → more
/// permissive.
///
/// Hysteresis (`minSpeechFrames` / `minSilenceFrames`) is in **VAD
/// windows** (32 ms each), so 3 / 10 maps to 96 ms / 320 ms — close
/// to EnergyVAD's tuned 90 ms / 300 ms. Same UX feel.
///
/// Source: [FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml)
/// (MIT). Fetch via `scripts/download-models.sh`. Once the model is
/// loaded, inference cost is < 1 ms per chunk on Apple Silicon.
public final class SileroVAD: VAD, @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        /// Probability threshold for "speech-likely." Range 0..1.
        public var threshold: Float
        public var minSpeechFrames: Int
        public var minSilenceFrames: Int

        public init(
            threshold: Float = 0.5,
            minSpeechFrames: Int = 3,
            minSilenceFrames: Int = 10
        ) {
            self.threshold = threshold
            self.minSpeechFrames = minSpeechFrames
            self.minSilenceFrames = minSilenceFrames
        }
    }

    /// Number of samples per inference chunk. Fixed by the model
    /// (`silero_vad.mlmodelc` declares MultiArray [1, 512]). At 16 kHz
    /// that's 32 ms.
    public static let chunkSamples: Int = 512

    public var config: Config
    private(set) public var inSpeech: Bool = false

    public var quietFrameCount: Int { quietFrames }
    public var silenceMidwayCount: Int {
        max(1, config.minSilenceFrames / 2)
    }

    private let model: MLModel
    private var windowBuffer: [Float] = []
    private var loudFrames: Int = 0
    private var quietFrames: Int = 0

    /// Init from an explicit model URL. Throws if CoreML can't load
    /// the file (wrong format, missing weights, etc.). Callers
    /// typically use `tryDefault()` instead, which handles the
    /// "model not yet downloaded" case gracefully.
    public init(modelURL: URL, config: Config = Config()) throws {
        let mlConfig = MLModelConfiguration()
        // ANE if available; CPU+GPU otherwise. .all lets CoreML pick.
        mlConfig.computeUnits = .all
        self.model = try MLModel(contentsOf: modelURL, configuration: mlConfig)
        self.config = config
    }

    /// Look for the Silero CoreML model in the user's Application
    /// Support directory (where `scripts/download-models.sh` deposits
    /// it). Returns `nil` if the model isn't installed yet — letting
    /// AppServices fall back to `EnergyVAD` without a fatal error.
    public static func tryDefault(config: Config = Config()) -> SileroVAD? {
        for url in defaultSearchPaths() {
            if let v = try? SileroVAD(modelURL: url, config: config) {
                return v
            }
        }
        return nil
    }

    /// Search paths in priority order. Application Support first
    /// (where the download script puts the file); the app bundle
    /// second (when we eventually ship the model bundled).
    public static func defaultSearchPaths() -> [URL] {
        var paths: [URL] = []
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        if let support {
            paths.append(
                support
                    .appendingPathComponent("Rocky")
                    .appendingPathComponent("Models")
                    .appendingPathComponent("silero-vad")
                    .appendingPathComponent("silero_vad.mlmodelc")
            )
        }
        if let bundled = Bundle.main.url(
            forResource: "silero_vad", withExtension: "mlmodelc"
        ) {
            paths.append(bundled)
        }
        return paths
    }

    public func reset() {
        inSpeech = false
        loudFrames = 0
        quietFrames = 0
        windowBuffer.removeAll(keepingCapacity: true)
    }

    public func ingest(samples: [Float], at timestamp: Date) -> VADTransition? {
        windowBuffer.append(contentsOf: samples)
        var transition: VADTransition? = nil
        // Process every full 512-sample window. If multiple windows
        // fit (rare — frames are 30/32 ms), the last transition wins;
        // earlier transitions during a dense burst are reflected in
        // the frame counters anyway.
        while windowBuffer.count >= Self.chunkSamples {
            let chunk = Array(windowBuffer.prefix(Self.chunkSamples))
            windowBuffer.removeFirst(Self.chunkSamples)
            let prob = predict(chunk)
            if let t = step(probability: prob, at: timestamp) {
                transition = t
            }
        }
        return transition
    }

    /// Same hysteresis state machine as `EnergyVAD.ingest`, just
    /// driven by Silero's probability output. Exposed so a unit test
    /// can drive it deterministically without loading CoreML.
    func step(probability: Float, at timestamp: Date) -> VADTransition? {
        let isLoud = probability >= config.threshold
        if isLoud {
            quietFrames = 0
            loudFrames += 1
            if !inSpeech, loudFrames >= config.minSpeechFrames {
                inSpeech = true
                return .speechStart(at: timestamp)
            }
        } else {
            loudFrames = 0
            quietFrames += 1
            if inSpeech, quietFrames >= config.minSilenceFrames {
                inSpeech = false
                return .speechEnd(at: timestamp)
            }
        }
        return nil
    }

    /// Run one CoreML forward pass on a 512-sample chunk. Returns the
    /// `vad_probability` scalar in [0, 1].
    private func predict(_ chunk: [Float]) -> Float {
        guard let array = try? MLMultiArray(
            shape: [1, NSNumber(value: Self.chunkSamples)],
            dataType: .float32
        ) else { return 0 }
        // Bulk-copy via the unsafe pointer rather than per-index
        // assignment — same safety, ~50× faster.
        chunk.withUnsafeBufferPointer { src in
            let dst = array.dataPointer.bindMemory(
                to: Float32.self, capacity: Self.chunkSamples
            )
            dst.update(from: src.baseAddress!, count: Self.chunkSamples)
        }
        let input = SileroInput(audioChunk: array)
        guard let out = try? model.prediction(from: input) else { return 0 }
        guard let prob = out.featureValue(for: "vad_probability"),
              let multi = prob.multiArrayValue,
              multi.count >= 1 else { return 0 }
        return multi[0].floatValue
    }
}

/// Single-input feature provider matching the model's `audio_chunk`
/// input. Defined here (rather than via Xcode's auto-generated Swift
/// class) so the model file can ship as a SwiftPM resource without
/// the auto-generation step. `MLFeatureProvider` requires class
/// conformance — Apple's protocol is `@objc`-bound.
private final class SileroInput: NSObject, MLFeatureProvider {
    let audioChunk: MLMultiArray
    init(audioChunk: MLMultiArray) {
        self.audioChunk = audioChunk
    }
    var featureNames: Set<String> { ["audio_chunk"] }
    func featureValue(for featureName: String) -> MLFeatureValue? {
        guard featureName == "audio_chunk" else { return nil }
        return MLFeatureValue(multiArray: audioChunk)
    }
}
