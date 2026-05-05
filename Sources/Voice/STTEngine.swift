import Foundation

/// Abstract STT engine. The first conformer (M4) is `EchoSTT` for deterministic
/// tests; the runtime conformer wraps WhisperKit (added in a follow-up).
public protocol STTEngine: Sendable {
    /// Transcribe a complete audio segment (16 kHz mono float32).
    func transcribe(samples: [Float], at sampleRate: Int) async throws -> Transcript

    /// Optional warm-up. Default: no-op.
    func warmUp() async throws
}

public extension STTEngine {
    func warmUp() async throws { /* default no-op */ }
}

public struct Transcript: Sendable, Equatable {
    public let text: String
    public let durationMs: Double
    public let confidence: Double

    public init(text: String, durationMs: Double = 0, confidence: Double = 1) {
        self.text = text
        self.durationMs = durationMs
        self.confidence = confidence
    }
}

/// Test conformer: returns whatever string was provided at construction time,
/// regardless of input. Useful to drive the wake/conversation pipeline in
/// unit tests without pulling in a real model.
public actor EchoSTT: STTEngine {
    private var nextTranscript: String

    public init(returning text: String = "") {
        self.nextTranscript = text
    }

    public func setNextTranscript(_ text: String) {
        self.nextTranscript = text
    }

    public func transcribe(samples: [Float], at sampleRate: Int) async throws -> Transcript {
        let durationMs = Double(samples.count) / Double(max(1, sampleRate)) * 1000
        return Transcript(text: nextTranscript, durationMs: durationMs)
    }
}
