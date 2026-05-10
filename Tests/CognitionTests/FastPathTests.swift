import Foundation
import Testing
@testable import Cognition

/// Unit tests for `FastPath`'s pattern matcher. Handler dispatch is
/// covered indirectly through CognitionEngine integration tests; this
/// suite focuses on the regex behaviour that decides "fast-path or
/// brain."
@Suite("FastPath matcher")
struct FastPathTests {

    @Test("matches time queries")
    func matchesTime() async {
        let fp = FastPath()
        let cases = [
            "what time is it",
            "what's the time",
            "what's the date today",
            "what day is it",
        ]
        for c in cases {
            #expect(await fp.match(c)?.intent == .time, "case: \(c)")
        }
    }

    @Test("matches weather with location capture")
    func matchesWeatherWithLocation() async {
        let fp = FastPath()
        guard let m = await fp.match("what's the weather in Berlin?") else {
            #expect(Bool(false), "should have matched")
            return
        }
        #expect(m.intent == .weather)
        #expect(m.groups.first == "berlin")
    }

    @Test("matches calendar with timeframe")
    func matchesCalendar() async {
        let fp = FastPath()
        guard let m = await fp.match("what's on tomorrow") else {
            #expect(Bool(false), "should have matched")
            return
        }
        #expect(m.intent == .calendar)
        #expect(m.groups.first == "tomorrow")
    }

    @Test("matches search with query capture")
    func matchesSearch() async {
        let fp = FastPath()
        guard let m = await fp.match("search the web for swift 6 concurrency") else {
            #expect(Bool(false), "should have matched")
            return
        }
        #expect(m.intent == .search)
        #expect(m.groups.first?.contains("swift 6 concurrency") == true)
    }

    @Test("matches remember with payload")
    func matchesRemember() async {
        let fp = FastPath()
        guard let m = await fp.match("remember that the spare key is in the drawer") else {
            #expect(Bool(false), "should have matched")
            return
        }
        #expect(m.intent == .remember)
        #expect(m.groups.first?.contains("spare key") == true)
    }

    @Test("greeting matches with or without name")
    func matchesGreeting() async {
        let fp = FastPath()
        for s in ["hi", "hello rocky", "good morning", "hey, rocky"] {
            #expect(await fp.match(s)?.intent == .greeting, "case: \(s)")
        }
    }

    @Test("non-trivial conversational queries fall through")
    func conversationalQueriesFallThrough() async {
        let fp = FastPath()
        let escapes = [
            "I'd like you to write me a poem about the sea",
            "can you explain how a Stewart platform works",
            "help me debug this Swift error",
            "the rocky road to success",
        ]
        for s in escapes {
            #expect(await fp.match(s) == nil, "should NOT have matched: \(s)")
        }
    }

    @Test("dispatch returns nil when no handler is registered")
    func dispatchWithoutHandler() async throws {
        let fp = FastPath()
        guard let m = await fp.match("what time is it") else {
            #expect(Bool(false), "should have matched")
            return
        }
        let reply = try await fp.dispatch(m)
        #expect(reply == nil)
    }

    @Test("dispatch invokes registered handler")
    func dispatchInvokesHandler() async throws {
        let fp = FastPath()
        await fp.register(.greeting) { match in
            "ack: \(match.utterance)"
        }
        guard let m = await fp.match("hi") else {
            #expect(Bool(false), "should have matched")
            return
        }
        let reply = try await fp.dispatch(m)
        #expect(reply == "ack: hi")
    }
}
