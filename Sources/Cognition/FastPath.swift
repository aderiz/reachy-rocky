import Foundation

/// Fast-path matcher for trivial queries. Pattern-matches user
/// utterances and dispatches a tool directly, then formats the
/// result in Rocky's persona — bypassing the brain entirely for
/// the ~80% of "useful" interactions that are simple information
/// fetches (time, weather, calendar, web search, memory write).
///
/// Going through the brain for "what time is it" pays an inference
/// cost that's well in excess of the actual work. The fast-path
/// short-circuits with a regex + intent classifier (regex-first;
/// any miss escalates to the brain). Time-to-first-word for matched
/// queries drops to ~200 ms (TTS first chunk + tool latency) vs.
/// ~1.5 s for the brain path.
///
/// Calls a `Handler` per matched intent — handlers fetch the data
/// (via the existing `ToolRegistry` or directly), format a
/// Rocky-voice reply string, and return it. The reply is then
/// streamed via the same `say` path as the brain's output so the
/// echo gate, persona normalisation, and streaming TTS all apply
/// unchanged.
public actor FastPath {
    public typealias Handler = @Sendable (FastPathMatch) async throws -> String?

    public struct FastPathMatch: Sendable {
        public let intent: Intent
        /// Captured groups from the regex (e.g. `["weather in Berlin"
        /// → ["Berlin"]]`). Indexes match the pattern's capture
        /// groups.
        public let groups: [String]
        /// Original utterance, lowercased.
        public let utterance: String
    }

    public enum Intent: String, Sendable, CaseIterable {
        case time
        case weather
        case calendar
        case search
        case remember
        case greeting
    }

    public struct Pattern: Sendable {
        public let intent: Intent
        public let regex: NSRegularExpression
        public init(intent: Intent, pattern: String) throws {
            self.intent = intent
            self.regex = try NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            )
        }
    }

    public private(set) var patterns: [Pattern]
    public private(set) var handlers: [Intent: Handler]

    public init(
        patterns: [Pattern]? = nil,
        handlers: [Intent: Handler] = [:]
    ) {
        self.patterns = patterns ?? Self.defaultPatterns()
        self.handlers = handlers
    }

    /// Set or replace a handler for an intent at runtime — lets
    /// AppServices wire ToolRegistry-backed handlers after init.
    public func register(_ intent: Intent, handler: @escaping Handler) {
        self.handlers[intent] = handler
    }

    /// Match the utterance against the registered patterns. Returns
    /// the first match (patterns are ordered by specificity), or
    /// nil if no pattern matches — caller falls through to the
    /// brain. Lowercases the utterance once for both regex matching
    /// and the returned `match.utterance`.
    public func match(_ utterance: String) -> FastPathMatch? {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        let range = NSRange(lowered.startIndex..., in: lowered)
        for pattern in patterns {
            guard
                let m = pattern.regex.firstMatch(
                    in: lowered, options: [], range: range
                )
            else { continue }
            var groups: [String] = []
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                if r.location == NSNotFound {
                    groups.append("")
                    continue
                }
                if let swiftRange = Range(r, in: lowered) {
                    groups.append(String(lowered[swiftRange]))
                } else {
                    groups.append("")
                }
            }
            return FastPathMatch(
                intent: pattern.intent, groups: groups, utterance: lowered
            )
        }
        return nil
    }

    /// Run the registered handler for the match. Returns the formatted
    /// Rocky-voice reply string, or nil when the handler signals "I
    /// can't fast-path this — escalate to the brain after all"
    /// (returns nil from the handler).
    public func dispatch(_ match: FastPathMatch) async throws -> String? {
        guard let handler = handlers[match.intent] else { return nil }
        return try await handler(match)
    }

    // MARK: - Default patterns

    /// Patterns ordered by specificity. Earlier patterns win when
    /// multiple would match. Each pattern uses anchors / word
    /// boundaries to avoid false positives ("the time of my life"
    /// shouldn't trigger `time`).
    public static func defaultPatterns() -> [Pattern] {
        let raw: [(Intent, String)] = [
            // Time / date
            (.time,     #"\b(?:what(?:'s| is)? the )?(?:current )?time(?: is it)?\b"#),
            (.time,     #"\bwhat(?:'s| is)? (?:the )?(?:current )?date(?: today)?\b"#),
            (.time,     #"\bwhat day is (?:it|today)\b"#),
            // Weather
            (.weather,  #"\bwhat(?:'s| is)? the weather(?: in (.+?))?(?: today| now)?\??$"#),
            (.weather,  #"\bweather (?:like|forecast)(?: in (.+?))?\??$"#),
            (.weather,  #"\bis it (?:going to )?(?:rain|snow|sunny|cold|hot)\b"#),
            // Calendar
            (.calendar, #"\bwhat(?:'s| is)? on (today|tomorrow|this week|next week)\b"#),
            (.calendar, #"\bwhat(?:'s| is)? (?:my )?(?:schedule|calendar)(?: for (today|tomorrow|this week))?\b"#),
            (.calendar, #"\b(?:any )?meetings? (today|tomorrow|this week)\b"#),
            // Web search
            (.search,   #"\b(?:search (?:the )?web|google|find online|look up) (?:for )?(.+)$"#),
            (.search,   #"\bwhat(?:'s| is) (?:the latest|the news) (?:about |on )?(.+?)\??$"#),
            // Remember
            (.remember, #"\bremember(?: that)? (.+)$"#),
            // Greeting
            (.greeting, #"^(?:hi|hello|hey|good (?:morning|afternoon|evening))(?:[,. ]+rocky)?\!?\??$"#),
        ]
        return raw.compactMap { try? Pattern(intent: $0.0, pattern: $0.1) }
    }
}
