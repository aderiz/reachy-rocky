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
    /// Whether the detector is currently latched in the speech
    /// state. `true` between a `.speechStart` and `.speechEnd`
    /// transition. Consumed by `VoiceCoordinator` so it knows
    /// whether to keep feeding the pre-roll buffer or grow the
    /// pending segment.
    var inSpeech: Bool { get }

    /// Consecutive non-speech frames since the last speech frame.
    /// Resets to 0 on every loud frame. Reaches `silenceMidwayCount`
    /// halfway through the silence accumulation phase, then
    /// `silenceEndCount` at firm speech-end. `VoiceCoordinator` uses
    /// the midway crossing to fire speculative STT — by the time
    /// the firm speech-end arrives the transcript is often ready.
    var quietFrameCount: Int { get }

    /// Half the count required for firm speech-end. Surfaces the
    /// VAD's internal threshold so the coordinator can detect
    /// "about-to-end" without needing to peek at config.
    var silenceMidwayCount: Int { get }

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

        /// Defaults tuned for a typical desk-mic / robot-array setup.
        /// - rmsThreshold 0.008: low enough that quiet / distant speech
        ///   still crosses it. The previous 0.015 was too strict and made
        ///   listen mode appear "stalled" (it never entered speech state
        ///   for someone not speaking close to the mic).
        /// - minSilenceFrames 10 (~300 ms at 30 ms frames): natural
        ///   mid-sentence pauses are typically 150–250 ms, so 300 ms
        ///   still covers them comfortably. The previous 480 ms over-
        ///   paid for the long-pause edge case and added perceptible
        ///   dead air after every utterance. Users with deliberate
        ///   long pauses will split into two utterances; that failure
        ///   mode is rare and the bot handles it cleanly.
        public init(
            rmsThreshold: Float = 0.008,
            minSpeechFrames: Int = 3,
            minSilenceFrames: Int = 10
        ) {
            self.rmsThreshold = rmsThreshold
            self.minSpeechFrames = minSpeechFrames
            self.minSilenceFrames = minSilenceFrames
        }
    }

    /// Live-mutable so callers (e.g. a calibration flow) can retune
    /// the threshold without restarting the listen pipeline. The
    /// frame-counting state (`loudFrames`/`quietFrames`) is intentionally
    /// not reset on threshold change — a re-tune mid-utterance just
    /// shifts the cutoff for subsequent frames.
    public var config: Config
    private(set) public var inSpeech: Bool = false
    private var loudFrames: Int = 0
    private var quietFrames: Int = 0

    public var quietFrameCount: Int { quietFrames }
    public var silenceMidwayCount: Int {
        max(1, config.minSilenceFrames / 2)
    }

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
