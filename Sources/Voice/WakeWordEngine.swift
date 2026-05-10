import Foundation
import Telemetry

/// Protocol for the wake-word detection backend. Two impls today:
///
///   - `STTWakeEngine` — wraps the existing `WakeFilter` + STT
///     transcript pattern match. Wake fires after the STT engine
///     finishes a final transcript and `WakeFilter.containsName`
///     finds the wake phrase. Latency: ≈ 1 s typical (VAD silence
///     window + STT transcribe time).
///
///   - `PorcupineStubEngine` — placeholder for a dedicated
///     keyword-spotting CNN. Returns "unavailable" until the
///     Picovoice .xcframework + access key are vendored. Latency
///     target once active: < 100 ms per wake event because the
///     model runs continuously on the audio stream and doesn't
///     wait for STT.
///
/// `VoiceCoordinator` always consults a `WakeWordEngine` before the
/// `WakeFilter`. If the engine reports `.detected`, the wake fires
/// immediately and the transcript-pattern path is bypassed. If it
/// reports `.idle` or `.unavailable`, the existing transcript-pattern
/// path runs as the fallback.
public protocol WakeWordEngine: Sendable {
    /// Whether the engine is currently active and watching for the
    /// wake word. When `false`, callers should fall back to the
    /// STT-pattern path (or treat the engine as a no-op).
    var isAvailable: Bool { get async }

    /// Subscribe to wake events. Each event signals the moment the
    /// engine matched the wake word in incoming audio. Consumers
    /// should immediately switch the system into "listening" state
    /// and start collecting the user's command.
    nonisolated func events() -> AsyncStream<WakeWordEvent>

    /// Feed a chunk of mic audio (16 kHz mono float32). The engine
    /// processes synchronously and emits to its `events()` stream
    /// when a wake match fires. No-op for engines that consume audio
    /// independently.
    func ingest(_ samples: [Float]) async
}

public struct WakeWordEvent: Sendable, Equatable {
    /// The wake phrase that matched.
    public let phrase: String
    /// Timestamp at which the engine declared the match.
    public let at: Date
    /// Confidence score in [0, 1] when available; nil for engines
    /// that don't expose one.
    public let confidence: Double?

    public init(phrase: String, at: Date, confidence: Double? = nil) {
        self.phrase = phrase
        self.at = at
        self.confidence = confidence
    }
}

// MARK: - STT-derived engine

/// The v0.1 wake path, wrapped in the new protocol shape. Always
/// available; consumes no audio (the wake decision lives in
/// `VoiceCoordinator.dispatchFinal` when it sees `WakeFilter.decide`).
/// `events()` returns an empty stream; the audio-ingest path is a
/// no-op. Callers that pick this engine continue to use the existing
/// `WakeFilter` flow unchanged.
public actor STTWakeEngine: WakeWordEngine {
    public init() {}
    public var isAvailable: Bool { true }
    public nonisolated func events() -> AsyncStream<WakeWordEvent> {
        AsyncStream { _ in /* empty — STT-derived path doesn't emit here */ }
    }
    public func ingest(_ samples: [Float]) async { /* no-op */ }
}

// MARK: - Porcupine stub

/// Placeholder for a Picovoice Porcupine-backed wake engine.
///
/// Picovoice's Porcupine ships as an iOS / macOS CocoaPod plus an
/// .xcframework artefact; it doesn't have a first-party SwiftPM
/// package. Wiring it into Rocky requires three things the user has
/// to do off-Rocky:
///
///   1. Sign up on console.picovoice.ai to obtain a free access key.
///   2. Train a custom "Rocky" wake phrase on the Console (the
///      transfer-learning trainer accepts ~30 utterances) → download
///      the resulting `.ppn` file.
///   3. Vendor `Porcupine.xcframework` into `Sources/Rocky/Resources/`
///      and add the binary target to `Package.swift`.
///
/// Until those land, this engine reports `isAvailable = false` and
/// the wake-engine factory in AppServices falls back to STTWakeEngine.
/// The protocol slot exists so the integration is a discrete future
/// PR, not a refactor: drop in the framework, swap out the stub for
/// a real detector class, ship.
public actor PorcupineStubEngine: WakeWordEngine {
    private let logBus: LogBus
    public init(logBus: LogBus) { self.logBus = logBus }

    public var isAvailable: Bool {
        // No working framework yet. When this flips to true,
        // VoiceCoordinator will route audio chunks through ingest().
        false
    }

    public nonisolated func events() -> AsyncStream<WakeWordEvent> {
        AsyncStream { _ in /* never emits */ }
    }

    public func ingest(_ samples: [Float]) async {
        // No-op until the real Porcupine engine is wired.
        _ = samples
    }
}
