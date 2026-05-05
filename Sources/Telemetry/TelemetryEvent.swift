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
    case ttsRequest(text: String, voiceRefId: String, firstChunkMs: Double?)
    case ttsChunk(index: Int, sinceStartMs: Double, bytes: Int)

    // Cognition
    case llmRequest(messageCount: Int, toolCount: Int)
    case llmChunk(sinceRequestMs: Double, contentDelta: String?, toolCallDelta: String?)
    case llmToolCall(name: String, args: String, id: String)
    case toolInvocation(name: String, args: String, result: String, latencyMs: Double, llmMessageId: String)

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
