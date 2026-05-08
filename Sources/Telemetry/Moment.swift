import Foundation

/// A *moment* — a narrative event in Rocky's day, surfaced at human
/// cadence rather than firehose. Per `docs/concepts/cockpit-design.md`
/// §5.1, moments replace the streaming `LogsView` as the primary
/// activity surface; the firehose lives behind a "Raw" tab.
///
/// Each moment is one row in the UI: an SF Symbol, a sentence, a
/// relative timestamp. Click expands to source detail (the original
/// transcript text, the tool args/result, the sidecar state).
///
/// Moments are produced by `MomentFeed`, which subscribes to `LogBus`
/// and coalesces noisy event streams into discrete narrative events:
/// three faceDetections of "Ade" in 5 s become one `recognised`; four
/// llm chunks become one `rockySaid`; a sidecar failing-and-recovering
/// becomes a `errorOccurred` followed by a `recovered` only after 60 s
/// of stable uptime.
public struct Moment: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public var kind: Kind

    public init(id: UUID = UUID(), timestamp: Date = Date(), kind: Kind) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
    }

    public enum Kind: Sendable, Equatable {
        case userSaid(text: String)
        case rockySaid(text: String, tools: [String])
        case rockyHeard(text: String)               // overheard, not addressed
        case toolUsed(name: String, summary: String)
        case recognised(person: String)
        case lostSightOf(person: String)
        case enrolled(person: String)
        case wokeUp
        case wentToSleep
        case errorOccurred(scope: String, message: String)
        case recovered(scope: String)
        case sidecarChanged(name: String, transition: String)
    }

    // MARK: - UI strings

    /// One sentence describing the moment, suitable for the moment-feed
    /// row. Templated; no millisecond timestamps, no hex IDs.
    public var sentence: String {
        switch kind {
        case .userSaid(let text):
            return "You said: \u{201C}\(text)\u{201D}"
        case .rockySaid(let text, let tools):
            if tools.isEmpty {
                return "Rocky said: \u{201C}\(text)\u{201D}"
            }
            let toolList = tools.joined(separator: ", ")
            return "Rocky used \(toolList) and said: \u{201C}\(text)\u{201D}"
        case .rockyHeard(let text):
            return "Rocky heard: \u{201C}\(text)\u{201D}"
        case .toolUsed(let name, let summary):
            return summary.isEmpty ? "Rocky used \(name)." : "Rocky used \(name) — \(summary)."
        case .recognised(let person):
            return "Rocky recognised \(person)."
        case .lostSightOf(let person):
            return "Rocky lost sight of \(person)."
        case .enrolled(let person):
            return "Enrolled \(person)."
        case .wokeUp:
            return "Rocky woke up."
        case .wentToSleep:
            return "Rocky went to sleep."
        case .errorOccurred(let scope, let message):
            return "\(scope) — \(message)"
        case .recovered(let scope):
            return "\(scope) recovered."
        case .sidecarChanged(let name, let transition):
            return "\(name) sidecar \(transition)."
        }
    }

    /// SF Symbol that fronts the row.
    public var symbolName: String {
        switch kind {
        case .userSaid:           return "person.fill"
        case .rockySaid:          return "brain"
        case .rockyHeard:         return "ear"
        case .toolUsed:           return "wrench.and.screwdriver"
        case .recognised:         return "sparkles"
        case .lostSightOf:        return "person.fill.questionmark"
        case .enrolled:           return "person.crop.circle.badge.plus"
        case .wokeUp:             return "sun.max.fill"
        case .wentToSleep:        return "moon.fill"
        case .errorOccurred:      return "exclamationmark.triangle.fill"
        case .recovered:          return "checkmark.circle.fill"
        case .sidecarChanged:     return "shippingbox"
        }
    }

    /// Coarse category. Used by the Activity tab's filter pills and the
    /// menu-bar popover's "Recent" section limit.
    public var category: Category {
        switch kind {
        case .userSaid, .rockySaid, .rockyHeard:           return .turn
        case .toolUsed:                                     return .turn
        case .recognised, .lostSightOf, .enrolled:         return .vision
        case .wokeUp, .wentToSleep:                        return .lifecycle
        case .errorOccurred, .recovered:                   return .error
        case .sidecarChanged:                              return .sidecar
        }
    }

    public enum Category: String, Sendable, Equatable, CaseIterable {
        case turn       // user / rocky / tool
        case vision     // face events
        case lifecycle  // wake / sleep
        case error
        case sidecar
    }
}
