import Foundation
import CoreGraphics
import RockyKit

/// Closed taxonomy of every event Rocky publishes, per plan §4.6.
/// Adding a case here is an explicit decision and forces the dashboard,
/// the SQLite archive, and any consumers to handle it.
public enum TelemetryEvent: Sendable {
    // Robot motion
    case motorCommand(source: MotionSource, target: MotionTarget)
    case motorState(RobotState)
    case stateStream(transition: String)
    case daemonStatus(periodMs: Double, readDtMs: Double, writeDtMs: Double)
    case robotLink(endpoint: String, status: Int, latencyMs: Double)

    // Vision
    case faceDetection(bbox: CGRect, confidence: Double, promptId: String)
    case faceTarget(yawRad: Double, pitchRad: Double, decayActive: Bool)

    // Voice
    case vadSegment(startMs: Double, endMs: Double)
    case sttPartial(text: String, confidence: Double)
    case sttFinal(text: String, totalMs: Double)
    case wakeMatch(name: String, transcript: String)
    case conversationWindow(transition: ConversationTransition, reason: String)
    /// AddressFilter dispatched a transcript to the brain. `reasons`
    /// carries the gates that contributed positively (e.g. ["wake",
    /// "loud", "face"]); score is the composite confidence in [0,1].
    case addressFilterAccept(text: String, score: Double, reasons: [String])
    /// AddressFilter dropped a transcript. `reasons` carries the
    /// negative gates (e.g. ["low_loudness", "no_face", "doa_off_axis"]).
    /// Pairs with vadSegment / sttFinal so the user can trace any
    /// dropped utterance back through the pipeline.
    case addressFilterDrop(text: String, score: Double, reasons: [String])
    case ttsRequest(text: String, voiceRefId: String, firstChunkMs: Double?)
    case ttsChunk(index: Int, sinceStartMs: Double, bytes: Int)
    /// First `play_sound` for this speak invocation has been issued —
    /// the robot speaker is producing audio NOW (the daemon's
    /// `play_sound` is non-blocking, so this fires within ~10 ms of
    /// the call returning). This is the closest signal to "Rocky
    /// started talking" the user perceives. Critical for profiling
    /// end-to-end latency. `sinceSpeakStartMs` = wall time from the
    /// `RobotTTS.speak`/`speakStreaming` entry to this point.
    case audioPlaybackStarted(filename: String, sinceSpeakStartMs: Double)

    // Cognition
    case llmRequest(messageCount: Int, toolCount: Int)
    case llmChunk(sinceRequestMs: Double, contentDelta: String?, toolCallDelta: String?)
    case llmToolCall(name: String, args: String, id: String)
    case toolInvocation(name: String, args: String, result: String, latencyMs: Double, llmMessageId: String)
    /// Brain stream completion. Mirrors `CognitionEngine.assistantFinal`
    /// onto LogBus so `TurnProfiler` (and anything else subscribing to
    /// the bus) can see brain TFT and total wall time without having
    /// to consume the cognition stream directly. Published once per
    /// turn-exit by `AppServices.drainBrainStream`.
    case brainResponse(firstChunkMs: Double?, totalMs: Double)
    /// One end-to-end profiling summary per turn from `TurnProfiler`.
    /// Carries every stage timing as structured fields so the Logs
    /// view (and any future archive consumer) can render the
    /// breakdown without re-parsing the summary string. Only emitted
    /// when `SettingsStore.profilingEnabled` is true.
    case turnProfile(summary: String, fields: [String: String])

    // Sidecars
    case sidecarLog(sidecar: String, level: LogLevel, message: String, fields: [String: String])
    case sidecarState(sidecar: String, transition: String)

    // Errors
    case error(scope: String, message: String, recoverable: Bool)

    public enum MotionSource: String, Sendable, Codable {
        case user, face, tool, emotion
    }

    public enum ConversationTransition: String, Sendable, Codable {
        case opened, extended, closed
    }

    public enum LogLevel: String, Sendable, Codable, Comparable {
        case trace, debug, info, warn, error

        private var rank: Int {
            switch self {
            case .trace: 0
            case .debug: 1
            case .info:  2
            case .warn:  3
            case .error: 4
            }
        }
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }
}

public struct TimestampedEvent: Sendable {
    public let timestamp: Date
    public let event: TelemetryEvent

    public init(timestamp: Date = .init(), event: TelemetryEvent) {
        self.timestamp = timestamp
        self.event = event
    }
}
