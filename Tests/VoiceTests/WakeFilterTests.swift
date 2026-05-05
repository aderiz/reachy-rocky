import Testing
import Foundation
import Voice

@Suite("WakeFilter")
struct WakeFilterTests {
    /// Thread-safe clock so a Sendable closure can read it across actor calls.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ now: Date) { self._now = now }
        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return _now
        }
        func advance(_ s: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            _now = _now.addingTimeInterval(s)
        }
    }

    /// Build a filter against a Clock instance.
    private func makeFilter(_ clock: Clock,
                            windowS: TimeInterval = 60) -> WakeFilter {
        WakeFilter(
            config: .init(wakeName: "rocky",
                          conversationWindowS: windowS,
                          stopPhrases: ["go to sleep", "stop listening"]),
            now: { clock.now }
        )
    }

    @Test("the rocky road does not match")
    func substringNoMatch() async {
        let f = makeFilter(Clock(Date()))
        let d = await f.decide(transcript: "the rocky road is delicious")
        #expect(d == .ignore)
    }

    @Test("rocky comma routes the whole transcript")
    func punctuationMatch() async {
        let f = makeFilter(Clock(Date()))
        let d = await f.decide(transcript: "Rocky, what's the weather?")
        if case .dispatch(let text, let reason) = d {
            #expect(text == "Rocky, what's the weather?")
            #expect(reason == .wakeMatch(name: "rocky"))
        } else {
            Issue.record("expected dispatch; got \(d)")
        }
    }

    @Test("various conversational openings route")
    func conversationalOpenings() async {
        for opener in ["Hi Rocky", "Hey Rocky", "OK Rocky", "Yeah Rocky", "Hello Rocky"] {
            let f = makeFilter(Clock(Date()))
            let d = await f.decide(transcript: "\(opener), how are you?")
            if case .dispatch = d {
                // ok
            } else {
                Issue.record("expected dispatch for '\(opener)'; got \(d)")
            }
        }
    }

    @Test("follow-up within the window doesn't need the wake word")
    func followUpWithinWindow() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let f = makeFilter(clock)

        // Wake match opens window
        let d1 = await f.decide(transcript: "Rocky, hi")
        if case .dispatch = d1 {} else { Issue.record("expected wake dispatch") }

        // 5s later, follow-up should still route (within window)
        clock.advance(5)
        let d2 = await f.decide(transcript: "what's the time?")
        if case .dispatch(_, let reason) = d2 {
            #expect(reason == .withinWindow)
        } else {
            Issue.record("expected within-window dispatch; got \(d2)")
        }
    }

    @Test("window closes after timeout; needs wake word again")
    func windowExpires() async {
        let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
        let f = makeFilter(clock, windowS: 60)

        _ = await f.decide(transcript: "rocky hello")
        clock.advance(70)
        let d = await f.decide(transcript: "anyone there?")
        #expect(d == .ignore)
    }

    @Test("stop phrase closes the window without dispatching")
    func stopPhrase() async {
        let f = makeFilter(Clock(Date()))
        _ = await f.decide(transcript: "rocky")
        let d = await f.decide(transcript: "ok go to sleep")
        if case .close = d {
            // ok
        } else {
            Issue.record("expected close; got \(d)")
        }
    }

    @Test("explicit openWindow + closeWindow controls work")
    func manualControls() async {
        let f = makeFilter(Clock(Date()))
        await f.openWindow()
        let d = await f.decide(transcript: "no wake word here")
        if case .dispatch = d {} else { Issue.record("expected dispatch after openWindow") }
        await f.closeWindow()
        let d2 = await f.decide(transcript: "still no wake")
        #expect(d2 == .ignore)
    }
}
