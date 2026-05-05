import Testing
import Foundation
import os
import Telemetry
import Voice

@Suite("VoiceCoordinator")
struct VoiceCoordinatorTests {

    /// Drives the coordinator with a scripted sequence of audio frames so the
    /// VAD transitions are deterministic.
    final class ScriptedFrameSource: VoiceCoordinator.AudioFrameSource, Sendable {
        private let queue = OSAllocatedUnfairLock<[[Float]]>(initialState: [])

        func enqueue(_ frame: [Float]) {
            queue.withLock { $0.append(frame) }
        }

        func nextFrame(maxSamples: Int) async -> [Float] {
            let next: [Float] = queue.withLock { q -> [Float] in
                q.isEmpty ? [] : q.removeFirst()
            }
            if next.isEmpty {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return next
        }
    }

    @Test("end-to-end: VAD start, speech, end -> STT fires, wake match dispatches")
    func endToEnd() async throws {
        let source = ScriptedFrameSource()
        let logBus = LogBus()
        let stt = EchoSTT(returning: "Rocky, hello")
        let wake = WakeFilter(config: .init(wakeName: "rocky"))
        let cfg = VoiceCoordinator.Config(sampleRate: 16_000, frameMs: 30, maxSegmentS: 4)
        let coord = VoiceCoordinator(
            source: source, stt: stt, wake: wake, logBus: logBus, config: cfg,
            vad: EnergyVAD(config: .init(
                rmsThreshold: 0.05, minSpeechFrames: 1, minSilenceFrames: 2
            ))
        )
        await coord.start()
        defer { Task { await coord.stop() } }

        let loud  = (0..<480).map { _ in Float.random(in: -0.5...0.5) }
        let quiet = Array(repeating: Float(0), count: 480)
        // 3 loud frames then 3 quiet frames triggers speechEnd.
        source.enqueue(loud); source.enqueue(loud); source.enqueue(loud)
        source.enqueue(quiet); source.enqueue(quiet); source.enqueue(quiet)

        // Wait for the dispatched final transcript.
        let outputs = coord.outputs
        let deadline = Date().addingTimeInterval(2.0)
        var dispatched: (text: String, reason: WakeFilter.Reason)?

        for await output in outputs {
            if case .finalText(let text, let didDispatch, let reason) = output, didDispatch {
                dispatched = (text, reason!)
                break
            }
            if Date() > deadline { break }
        }

        #expect(dispatched != nil, "expected a dispatched final")
        #expect(dispatched?.text == "Rocky, hello")
        if case .wakeMatch(let name) = dispatched?.reason {
            #expect(name == "rocky")
        } else {
            Issue.record("expected wake match; got \(String(describing: dispatched?.reason))")
        }
    }
}
