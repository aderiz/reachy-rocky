import Foundation
import Telemetry

/// `STTEngine` that races two engines and returns the first
/// non-empty transcript. Designed to pair Apple's SFSpeechRecognizer
/// (fast: ~50–150 ms post-speech, on-device on macOS 13+) with
/// MLX-Whisper (slower: ~250–500 ms, more accurate on noisy /
/// distant speech).
///
/// Behaviour:
///   - Both engines are kicked off in parallel on the same audio.
///   - First result wins IF its `text` is non-empty.
///   - If the first finisher returned empty (Apple's "no speech",
///     Whisper's no-speech gate, etc.), the second finisher's
///     result is used.
///   - Both empty → empty transcript, treated downstream as
///     "no transcription this segment".
///
/// Net effect: the user experiences whichever engine handles their
/// utterance well today, instead of paying the worst-case latency
/// of a single engine. Apple Speech catches the easy 80% in ~100 ms;
/// MLX-Whisper rescues the noisy / distant 20% that Apple misses.
public actor RacingSTT: STTEngine {
    private let fast: any STTEngine
    private let accurate: any STTEngine
    private let logBus: LogBus

    public init(
        fast: any STTEngine,
        accurate: any STTEngine,
        logBus: LogBus
    ) {
        self.fast = fast
        self.accurate = accurate
        self.logBus = logBus
    }

    public func warmUp() async throws {
        // Warm both in parallel so the user's first utterance
        // doesn't pay either engine's cold start.
        async let f: Void = { try? await self.fast.warmUp() }()
        async let a: Void = { try? await self.accurate.warmUp() }()
        _ = await (f, a)
    }

    public func transcribe(
        samples: [Float], at sampleRate: Int
    ) async throws -> Transcript {
        let fast = self.fast
        let accurate = self.accurate
        let bus = self.logBus

        enum Source: String, Sendable { case fast, accurate }

        return await withTaskGroup(of: (Source, Transcript?).self) { group in
            group.addTask {
                let started = Date()
                let t = try? await fast.transcribe(samples: samples, at: sampleRate)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                await bus.publish(.sidecarLog(
                    sidecar: "stt-race", level: .debug,
                    message: "fast ms=\(ms) text=\"\((t?.text ?? "").prefix(60))\"",
                    fields: [:]
                ))
                return (.fast, t)
            }
            group.addTask {
                let started = Date()
                let t = try? await accurate.transcribe(samples: samples, at: sampleRate)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                await bus.publish(.sidecarLog(
                    sidecar: "stt-race", level: .debug,
                    message: "accurate ms=\(ms) text=\"\((t?.text ?? "").prefix(60))\"",
                    fields: [:]
                ))
                return (.accurate, t)
            }

            // First result.
            guard let first = await group.next() else {
                return Transcript(text: "", durationMs: 0, confidence: 0)
            }
            // If the first finisher returned usable text, take it
            // and cancel the loser. This is the happy path.
            if let r = first.1, !r.text.isEmpty {
                group.cancelAll()
                await bus.publish(.sidecarLog(
                    sidecar: "stt-race", level: .info,
                    message: "winner=\(first.0.rawValue) (first)",
                    fields: ["text": r.text]
                ))
                return r
            }
            // First was empty — wait for the loser to land in case
            // it has a better answer.
            guard let second = await group.next() else {
                return first.1 ?? Transcript(
                    text: "", durationMs: 0, confidence: 0
                )
            }
            if let r = second.1, !r.text.isEmpty {
                await bus.publish(.sidecarLog(
                    sidecar: "stt-race", level: .info,
                    message: "winner=\(second.0.rawValue) (fallback after empty \(first.0.rawValue))",
                    fields: ["text": r.text]
                ))
                return r
            }
            // Both empty. Prefer whichever engine returned a real
            // transcript object (i.e. not nil from a thrown error).
            return first.1 ?? second.1 ?? Transcript(
                text: "", durationMs: 0, confidence: 0
            )
        }
    }
}
