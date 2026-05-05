import Foundation

/// Pragmatic energy-based voice activity detector.
///
/// Computes RMS over a sliding window. Above a calibrated threshold for
/// `minSpeechFrames` consecutive frames → `speechStart`. Below threshold for
/// `minSilenceFrames` consecutive frames → `speechEnd`. State + the current
/// segment's start timestamp are exposed.
///
/// Trade-offs vs. Silero: less robust to non-speech transients (typing, fans),
/// but no ML dep, no model download, and easy to reason about. Silero swap is
/// a future drop-in via the same `VAD` protocol.
public protocol VAD: Sendable {
    /// Feed a frame. Returns the resulting transition (if any).
    mutating func ingest(samples: [Float], at timestamp: Date) -> VADTransition?

    /// Reset internal state. Useful at session boundaries.
    mutating func reset()
}

public enum VADTransition: Sendable, Equatable {
    case speechStart(at: Date)
    case speechEnd(at: Date)
}

public struct EnergyVAD: VAD {
    public struct Config: Sendable, Equatable {
        public var rmsThreshold: Float
        public var minSpeechFrames: Int
        public var minSilenceFrames: Int

        public init(
            rmsThreshold: Float = 0.008,
            minSpeechFrames: Int = 3,
            minSilenceFrames: Int = 14
        ) {
            self.rmsThreshold = rmsThreshold
            self.minSpeechFrames = minSpeechFrames
            self.minSilenceFrames = minSilenceFrames
        }
    }

    private(set) public var config: Config
    private(set) public var inSpeech: Bool = false
    private var loudFrames: Int = 0
    private var quietFrames: Int = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func reset() {
        inSpeech = false
        loudFrames = 0
        quietFrames = 0
    }

    public mutating func ingest(samples: [Float], at timestamp: Date) -> VADTransition? {
        let rms = Self.rms(samples)
        let isLoud = rms >= config.rmsThreshold
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

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Double = 0
        for s in samples { sumSq += Double(s) * Double(s) }
        return Float((sumSq / Double(samples.count)).squareRoot())
    }
}
