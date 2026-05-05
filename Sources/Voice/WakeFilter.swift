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
    /// We require the wake word to APPEAR AS THE ADDRESSED PARTY at the start
    /// of the transcript — not just be a token somewhere in the sentence.
    /// "Rocky, what time is it?" matches; "the rocky road is delicious"
    /// doesn't. Allowed leading words: "hey", "ok", "okay", "yo".
    ///
    /// Matches:
    ///   "rocky"
    ///   "Rocky, hi"
    ///   "Rocky! …"
    ///   "Hey Rocky, …"
    ///   "Ok rocky, …"
    /// Does NOT match:
    ///   "the rocky road"          (not addressing)
    ///   "rockyard"                (substring, no boundary)
    ///   "I love rocky"            (not at start)
    public static func containsName(_ transcript: String, name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let needle = name.lowercased()
        // Strip leading punctuation/whitespace, then optionally a single
        // attention-getter word ("hey", "ok"/"okay", "yo") followed by space.
        var lc = transcript.lowercased()
        lc = lc.trimmingCharacters(in: .whitespacesAndNewlines)
        lc = lc.drop(while: { !$0.isLetter && $0 != "'" }).lowercased()
        for prefix in ["hey ", "ok ", "okay ", "yo "] {
            if lc.hasPrefix(prefix) {
                lc = String(lc.dropFirst(prefix.count))
                break
            }
        }
        // Now `lc` should *start* with the needle, followed by either
        // end-of-string or a non-letter (space, comma, period, etc.).
        guard lc.hasPrefix(needle) else { return false }
        let after = lc.dropFirst(needle.count)
        if after.isEmpty { return true }
        return !after.first!.isLetter
    }
}
