import Testing
import Foundation
import Voice

@Suite("AddressFilter")
struct AddressFilterTests {
    // Mirrors the cases on the WakeFilter side: nothing here ever
    // talks to a real mic / face tracker / TTS; tests assemble
    // `Signals` directly and assert on the `Decision`.

    private func makeFilter(
        _ overrides: (inout AddressFilter.Config) -> Void = { _ in }
    ) -> AddressFilter {
        var cfg = AddressFilter.Config()
        overrides(&cfg)
        return AddressFilter(config: cfg)
    }

    /// A "loud, on-axis, face visible" signal bundle by default — tests
    /// flip individual fields off to exercise specific gates.
    private func goodSignals(
        text: String = "what time is it",
        wake: WakeFilter.Reason = .withinWindow,
        micSource: String = "robot",
        peakRMS: Double = 0.10,
        doa: Double? = 0.05,
        face: TimeInterval? = 1.0
    ) -> AddressFilter.Signals {
        AddressFilter.Signals(
            text: text,
            sttConfidence: 0.95,
            segmentPeakRMS: peakRMS,
            segmentMeanRMS: peakRMS * 0.5,
            roomNoiseCeiling: 0.005,
            doaRad: doa,
            doaIsSpeech: doa != nil ? true : nil,
            faceVisibleAgeS: face,
            wakeReason: wake,
            ttsActive: false,
            micSource: micSource
        )
    }

    // MARK: - Hard accepts / rejects

    @Test("wake-name match dispatches regardless of all other signals")
    func wakeOverride() async {
        let f = makeFilter()
        // Deliberately failing every other gate. The wake match
        // should still produce dispatch.
        let s = AddressFilter.Signals(
            text: "rocky",
            sttConfidence: 0.10,
            segmentPeakRMS: 0.001,
            segmentMeanRMS: 0.0005,
            roomNoiseCeiling: 0.005,
            doaRad: 3.0,       // way off-axis
            doaIsSpeech: false,
            faceVisibleAgeS: nil,
            wakeReason: .wakeMatch(name: "rocky"),
            ttsActive: false,
            micSource: "robot"
        )
        let d = await f.decide(s)
        guard case let .dispatch(_, reasons, engaged) = d else {
            Issue.record("expected dispatch; got \(d)"); return
        }
        #expect(reasons.contains("wake"))
        #expect(engaged == true)
    }

    @Test("echo-tail drops everything while Rocky is speaking")
    func echoTailDrops() async {
        let f = makeFilter()
        var s = goodSignals()
        s.ttsActive = true
        let d = await f.decide(s)
        guard case let .drop(_, reasons) = d else {
            Issue.record("expected drop; got \(d)"); return
        }
        #expect(reasons.contains("echo_tail"))
    }

    @Test("junk phrase 'thank you' drops at any confidence")
    func junkPhraseDrops() async {
        let f = makeFilter()
        let s = goodSignals(text: "thank you")
        let d = await f.decide(s)
        guard case let .drop(_, reasons) = d else {
            Issue.record("expected drop; got \(d)"); return
        }
        #expect(reasons.contains("junk_phrase"))
    }

    @Test("low confidence drops")
    func lowConfidenceDrops() async {
        let f = makeFilter()
        var s = goodSignals(text: "hello there")
        s.sttConfidence = 0.1
        let d = await f.decide(s)
        guard case let .drop(_, reasons) = d else {
            Issue.record("expected drop; got \(d)"); return
        }
        #expect(reasons.contains("low_confidence"))
    }

    @Test("short bypass words pass the confidence gate")
    func shortBypass() async {
        let f = makeFilter()
        var s = goodSignals(text: "yes")
        s.sttConfidence = 0.1
        let d = await f.decide(s)
        // 'yes' bypasses confidence; it then meets loud + face +
        // doa, so the gate accepts.
        guard case .dispatch = d else {
            Issue.record("expected dispatch; got \(d)"); return
        }
    }

    // MARK: - Strict scored gate

    @Test("loud, on-axis, face visible → dispatch")
    func happyPath() async {
        let f = makeFilter()
        let s = goodSignals()
        let d = await f.decide(s)
        guard case let .dispatch(_, reasons, engaged) = d else {
            Issue.record("expected dispatch; got \(d)"); return
        }
        #expect(reasons.contains("loud"))
        #expect(reasons.contains("face"))
        #expect(reasons.contains("doa_on_axis"))
        #expect(engaged == true)
    }

    @Test("loud but off-axis (robot mic) → drop with doa_off_axis")
    func loudOffAxisDrops() async {
        let f = makeFilter()
        var s = goodSignals()
        s.doaRad = 1.6   // way outside ±0.45 rad cone
        s.doaIsSpeech = true
        let d = await f.decide(s)
        guard case let .drop(_, reasons) = d else {
            Issue.record("expected drop; got \(d)"); return
        }
        #expect(reasons.contains("doa_off_axis"))
    }

    @Test("quiet → drop with low_loudness")
    func quietDrops() async {
        let f = makeFilter()
        var s = goodSignals()
        s.segmentPeakRMS = 0.003   // below floor (default 0.012)
        let d = await f.decide(s)
        guard case let .drop(_, reasons) = d else {
            Issue.record("expected drop; got \(d)"); return
        }
        #expect(reasons.contains("low_loudness"))
    }

    @Test("Mac mic + face + verb prefix → dispatch (DoA skipped)")
    func macMicPasses() async {
        let f = makeFilter()
        let s = goodSignals(
            text: "what is the weather",
            micSource: "mac",
            doa: nil,
            face: 1.0
        )
        let d = await f.decide(s)
        guard case let .dispatch(_, reasons, _) = d else {
            Issue.record("expected dispatch; got \(d)"); return
        }
        // Mac mic has no DoA — should not contribute a doa_on_axis
        // reason, but should still accept on loudness + engagement.
        #expect(reasons.contains("loud"))
        #expect(reasons.contains("face"))
        #expect(!reasons.contains("doa_on_axis"))
    }

    @Test("Mac mic + no face + plain phrase → drop (strict mode)")
    func macMicNoEngagementDrops() async {
        let f = makeFilter()
        let s = goodSignals(
            text: "hmm interesting",  // no verb prefix
            micSource: "mac",
            doa: nil,
            face: nil
        )
        let d = await f.decide(s)
        guard case let .drop(_, reasons) = d else {
            Issue.record("expected drop; got \(d)"); return
        }
        #expect(reasons.contains("no_engagement"))
    }

    @Test("Mac mic + no face + verb prefix → dispatch")
    func macMicVerbPrefixSaves() async {
        let f = makeFilter()
        let s = goodSignals(
            text: "what is happening",
            micSource: "mac",
            doa: nil,
            face: nil
        )
        let d = await f.decide(s)
        guard case .dispatch = d else {
            Issue.record("expected dispatch; got \(d)"); return
        }
    }

    @Test("disabling the filter makes it transparent")
    func disabledFilterPasses() async {
        let f = makeFilter { $0.enabled = false }
        // Even something that would normally drop hard (junk phrase
        // + tts active + very off-axis) should pass when disabled.
        var s = goodSignals(text: "thank you")
        s.ttsActive = true
        let d = await f.decide(s)
        guard case let .dispatch(_, reasons, _) = d else {
            Issue.record("expected dispatch; got \(d)"); return
        }
        #expect(reasons.contains("filter_disabled"))
    }
}
