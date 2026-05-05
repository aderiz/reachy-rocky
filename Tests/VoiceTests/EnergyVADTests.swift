import Testing
import Foundation
import Voice

@Suite("EnergyVAD")
struct EnergyVADTests {
    private func loud(_ n: Int = 480, amp: Float = 0.3) -> [Float] {
        (0..<n).map { _ in amp * (Float.random(in: -1...1)) }
    }
    private func silent(_ n: Int = 480) -> [Float] {
        Array(repeating: 0, count: n)
    }

    @Test("speechStart fires after enough loud frames")
    func speechStart() {
        var vad = EnergyVAD(config: .init(rmsThreshold: 0.05,
                                          minSpeechFrames: 3,
                                          minSilenceFrames: 5))
        var transition: VADTransition?
        for _ in 0..<2 {
            transition = vad.ingest(samples: loud(), at: Date())
            #expect(transition == nil)
        }
        transition = vad.ingest(samples: loud(), at: Date())
        if case .some(.speechStart) = transition {
            // ok
        } else {
            Issue.record("expected speechStart, got \(String(describing: transition))")
        }
        #expect(vad.inSpeech)
    }

    @Test("speechEnd fires after enough silent frames")
    func speechEnd() {
        var vad = EnergyVAD(config: .init(rmsThreshold: 0.05,
                                          minSpeechFrames: 1,
                                          minSilenceFrames: 3))
        _ = vad.ingest(samples: loud(), at: Date()) // start
        #expect(vad.inSpeech)
        for _ in 0..<2 {
            #expect(vad.ingest(samples: silent(), at: Date()) == nil)
        }
        let last = vad.ingest(samples: silent(), at: Date())
        if case .some(.speechEnd) = last {
            // ok
        } else {
            Issue.record("expected speechEnd, got \(String(describing: last))")
        }
        #expect(!vad.inSpeech)
    }

    @Test("intermittent loud frames don't trigger spurious starts")
    func noFalseStart() {
        var vad = EnergyVAD(config: .init(rmsThreshold: 0.05,
                                          minSpeechFrames: 4,
                                          minSilenceFrames: 4))
        // Two loud frames then silence — shouldn't latch.
        _ = vad.ingest(samples: loud(), at: Date())
        _ = vad.ingest(samples: loud(), at: Date())
        _ = vad.ingest(samples: silent(), at: Date())
        #expect(!vad.inSpeech)
    }
}
