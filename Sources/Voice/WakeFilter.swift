import Foundation

/// State machine for "Rocky, ..." wake detection + conversation window.
///
/// SLEEPING -> wake match in final transcript -> DISPATCHED -> OPEN_window.
/// During OPEN_window every final transcript is **admitted** (not auto-
/// dispatched); the downstream `AddressFilter` then decides whether the
/// admitted transcript was actually addressed to Rocky. The window only
/// extends when the caller invokes `extendOnEngaged()` after a genuinely
/// engaged dispatch (loud + face / DoA / verb). Pure `.withinWindow`
/// hits that don't show real engagement do not perpetuate the window —
/// this prevents hallucinations from holding it open indefinitely.
///
/// Closes on timeout, mute, or explicit "stop listening" / "go to sleep".
public actor WakeFilter {
    public struct Config: Sendable, Equatable {
        public var wakeName: String
        public var conversationWindowS: TimeInterval
        public var stopPhrases: [String]

        public init(
            wakeName: String = "rocky",
            conversationWindowS: TimeInterval = 20,
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
            // Admit only — the AddressFilter decides whether to
            // dispatch and whether this transcript was *engaged*
            // (and therefore extends the window). The window does
            // NOT auto-extend here; callers must invoke
            // `extendOnEngaged()` after an engaged dispatch.
            return .dispatch(transcript: transcript, reason: .withinWindow)
        }

        if Self.containsName(transcript, name: config.wakeName) {
            // Wake-name match opens (or refreshes) the window. The
            // explicit address is itself the engagement evidence.
            extendWindow()
            return .dispatch(transcript: transcript,
                             reason: .wakeMatch(name: config.wakeName))
        }

        return .ignore
    }

    /// Refresh the conversation window because the last admitted
    /// transcript showed real engagement (loud + face / DoA / verb
    /// prefix). The AddressFilter signals this via its `.dispatch`
    /// decision's `engaged` flag; `AppServices.handleVoice` calls
    /// this from there. Idempotent and safe to call when the
    /// window is currently sleeping (no-op).
    @discardableResult
    public func extendOnEngaged() -> Date? {
        guard state.isOpen else { return nil }
        extendWindow()
        if case .open(let until) = state { return until }
        return nil
    }

    /// Open (or re-open) the conversation window because Rocky just
    /// finished speaking. The user almost always responds within a
    /// few seconds of Rocky's reply, so this gives them a fresh
    /// `conversationWindowS` from NOW even if the original window
    /// expired while Rocky was responding (a 30 s answer inside a
    /// 20 s window would otherwise force the user to say "Rocky"
    /// again). Differs from `extendOnEngaged` in that it always
    /// reopens, never no-ops.
    @discardableResult
    public func keepAliveAfterSpeaking() -> Date {
        let deadline = now().addingTimeInterval(config.conversationWindowS)
        state = .open(until: deadline)
        return deadline
    }

    private func extendWindow() {
        let deadline = now().addingTimeInterval(config.conversationWindowS)
        state = .open(until: deadline)
    }

    private func hasStopPhrase(_ transcript: String) -> Bool {
        let lc = transcript.lowercased()
        // Lowercase BOTH sides — defensive against a configured
        // phrase like "Stop Listening" that would otherwise never
        // match a lowercase transcript.
        return config.stopPhrases.contains { lc.contains($0.lowercased()) }
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

        // Apple Speech regularly mishears "rocky" as one of these
        // spellings on noisy mics. Trimmed from the previous list
        // (`rockie`/`roque` are common standalone names that fired
        // false positives when other people in the room were
        // mentioned by name) to just the homophone variants.
        let acceptables: Set<String>
        if needle == "rocky" {
            acceptables = ["rocky", "rockey", "rocki"]
        } else {
            acceptables = [needle]
        }

        let tokens = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        // Look 5 tokens deep instead of 3 so vocative-anywhere
        // patterns like "hi there my friend Rocky" match. The
        // article-prefix guard still rejects "the rocky road" /
        // "a rocky climb" → those legitimately aren't addressing
        // the bot.
        let lookahead = Array(tokens.prefix(5))
        for (i, t) in lookahead.enumerated() {
            guard acceptables.contains(t) else { continue }
            if i == 0 { return true }
            let prev = lookahead[i - 1]
            // Article check is per-position. The previous code did
            // `return false` on an article match, abandoning the
            // rest of the prefix — so `"the rocky rocky go"` was
            // rejected even though the SECOND "rocky" (with prev
            // = "rocky", not an article) was a valid match. Now
            // an article-prefixed hit is just SKIPPED; later
            // positions still get a chance.
            if articles.contains(prev) { continue }
            return true
        }
        return false
    }
}
