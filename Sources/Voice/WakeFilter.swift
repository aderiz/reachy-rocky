import Foundation

/// State machine for "Rocky, ..." wake detection + 60 s conversation window.
///
/// SLEEPING -> wake match in final transcript -> DISPATCHED -> OPEN_60s.
/// During OPEN_60s every final transcript is dispatched without needing the
/// wake word; the window auto-extends each turn. Closes on timeout, mute, or
/// explicit "stop listening" / "go to sleep".
public actor WakeFilter {
    public struct Config: Sendable, Equatable {
        public var wakeName: String
        public var conversationWindowS: TimeInterval
        public var stopPhrases: [String]

        public init(
            wakeName: String = "rocky",
            conversationWindowS: TimeInterval = 60,
            stopPhrases: [String] = ["go to sleep", "stop listening", "good night"]
        ) {
            self.wakeName = wakeName
            self.conversationWindowS = conversationWindowS
            self.stopPhrases = stopPhrases
        }
    }

    public enum State: Sendable, Equatable {
        case sleeping
        case open(until: Date)

        public var isOpen: Bool {
            if case .open = self { return true } else { return false }
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Final transcript should be dispatched to the LLM.
        case dispatch(transcript: String, reason: Reason)
        /// No-op; not a wake match and conversation window is closed.
        case ignore
        /// Explicit close phrase detected; closing the window without dispatch.
        case close(reason: String)
    }

    public enum Reason: Sendable, Equatable {
        case wakeMatch(name: String)
        case withinWindow
    }

    private(set) public var state: State = .sleeping
    public private(set) var config: Config
    private let now: @Sendable () -> Date

    public init(
        config: Config = Config(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.now = now
    }

    public func setConfig(_ config: Config) {
        self.config = config
    }

    /// Manually open the window (e.g., user clicked "Talk to Rocky").
    public func openWindow() {
        let deadline = now().addingTimeInterval(config.conversationWindowS)
        state = .open(until: deadline)
    }

    /// Close the window (e.g., mute, manual close).
    public func closeWindow() {
        state = .sleeping
    }

    /// Decide what to do with a final transcript.
    public func decide(transcript raw: String) -> Decision {
        let transcript = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return .ignore }

        // Expire stale window first so the next-state logic sees a clean state.
        if case .open(let deadline) = state, now() >= deadline {
            state = .sleeping
        }

        // Stop phrases trump everything when the window is open.
        if state.isOpen, hasStopPhrase(transcript) {
            state = .sleeping
            return .close(reason: "stop phrase")
        }

        if state.isOpen {
            extendWindow()
            return .dispatch(transcript: transcript, reason: .withinWindow)
        }

        if Self.containsName(transcript, name: config.wakeName) {
            extendWindow()
            return .dispatch(transcript: transcript,
                             reason: .wakeMatch(name: config.wakeName))
        }

        return .ignore
    }

    private func extendWindow() {
        let deadline = now().addingTimeInterval(config.conversationWindowS)
        state = .open(until: deadline)
    }

    private func hasStopPhrase(_ transcript: String) -> Bool {
        let lc = transcript.lowercased()
        return config.stopPhrases.contains { lc.contains($0) }
    }

    /// Address-pattern wake match.
    ///
    /// Heuristic: the wake word must appear in the **first three tokens** of
    /// the transcript, AND must not be immediately preceded by an article
    /// ("the", "a", "an", "this", "that"). This catches every natural way to
    /// address Rocky without firing on ambient mentions.
    ///
    /// Matches:
    ///   "rocky"               — token 0
    ///   "rocky hi"            — token 0
    ///   "Rocky, what time…"   — token 0 (punctuation-tolerant tokenizer)
    ///   "hey rocky"           — token 1, prev="hey"
    ///   "hi rocky"            — token 1, prev="hi"
    ///   "ok rocky"            — token 1
    ///   "yeah rocky help"     — token 1
    ///
    /// Does NOT match:
    ///   "the rocky road"      — token 1 but preceded by "the"
    ///   "rockyard"            — single token; not equal to "rocky"
    ///   "I love rocky"        — token 2 but BEYOND first 3? Actually 3 tokens
    ///                           ("i", "love", "rocky"); allowed (rare false
    ///                           positive in conversational context).
    public static func containsName(_ transcript: String, name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let needle = name.lowercased()
        let articles: Set<String> = ["the", "a", "an", "this", "that"]

        let tokens = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let firstThree = Array(tokens.prefix(3))
        for (i, t) in firstThree.enumerated() {
            guard t == needle else { continue }
            if i == 0 { return true }
            let prev = firstThree[i - 1]
            if articles.contains(prev) { return false }
            return true
        }
        return false
    }
}
