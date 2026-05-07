import Foundation
import Telemetry

/// Wires the voice pipeline together. Reads audio from a `MicService`'s ring
/// buffer at a fixed cadence, runs energy VAD, and on `speechEnd` hands the
/// captured segment to an `STTEngine`. Final transcripts pass through the
/// `WakeFilter`; dispatched transcripts are surfaced via `dispatchedTranscripts`.
///
/// Designed to be testable: the source of audio frames is abstracted as
/// `AudioFrameSource` so tests can drive synthetic frames without touching
/// AVAudioEngine.
public actor VoiceCoordinator {
    public protocol AudioFrameSource: Sendable {
        /// Pull up to `frameSamples` worth of audio. Returns whatever is
        /// currently available (may be < frameSamples). Append-only.
        func nextFrame(maxSamples: Int) async -> [Float]
    }

    public struct Config: Sendable {
        public var sampleRate: Int
        public var frameMs: Int            // frame size for VAD
        public var maxSegmentS: Double     // hard cap on a segment's length

        public init(
            sampleRate: Int = 16_000,
            frameMs: Int = 30,
            maxSegmentS: Double = 12
        ) {
            self.sampleRate = sampleRate
            self.frameMs = frameMs
            self.maxSegmentS = maxSegmentS
        }
    }

    public enum Output: Sendable {
        case partial(text: String)
        case finalText(text: String, dispatched: Bool, reason: WakeFilter.Reason?)
        case windowOpened(until: Date)
        case windowClosed(reason: String)
    }

    private let source: AudioFrameSource
    private var stt: STTEngine
    private let wake: WakeFilter
    private let logBus: LogBus
    public private(set) var config: Config
    private var vad: EnergyVAD
    private var pendingSegment: [Float] = []
    private var segmentStart: Date?
    private var pumpTask: Task<Void, Never>?
    /// In-flight STT task. The pump never awaits transcription directly —
    /// it spawns this task and continues draining frames. If a second
    /// speechEnd arrives while one is in-flight we drop the segment
    /// rather than queueing (latest user audio matters more than backed-
    /// up history, and queueing turns into a multi-second stall).
    private var sttTask: Task<Void, Never>?
    /// Fires `.windowClosed` when the wake-filter conversation window
    /// hits its deadline without an extending follow-up. Cancelled and
    /// rescheduled on every dispatch so the timer always reflects the
    /// latest deadline.
    private var windowCloseTask: Task<Void, Never>?

    public nonisolated let outputs: AsyncStream<Output>
    private let outputsContinuation: AsyncStream<Output>.Continuation

    public init(
        source: AudioFrameSource,
        stt: STTEngine,
        wake: WakeFilter,
        logBus: LogBus,
        config: Config = Config(),
        vad: EnergyVAD = EnergyVAD()
    ) {
        self.source = source
        self.stt = stt
        self.wake = wake
        self.logBus = logBus
        self.config = config
        self.vad = vad
        var c: AsyncStream<Output>.Continuation!
        self.outputs = AsyncStream<Output>(
            bufferingPolicy: .bufferingNewest(64)
        ) { cont in c = cont }
        self.outputsContinuation = c
    }

    public func start() {
        guard pumpTask == nil else { return }
        // Clean state at the start of every listen session — no leftover
        // audio from a previous session, no stale VAD speech-mode latch.
        pendingSegment.removeAll(keepingCapacity: true)
        segmentStart = nil
        vad.reset()
        pumpTask = Task { [weak self] in
            await self?.pumpLoop()
        }
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        sttTask?.cancel()
        sttTask = nil
        windowCloseTask?.cancel()
        windowCloseTask = nil
        // Drop any half-captured segment so the next start() doesn't
        // resume with stale audio prepended to fresh frames.
        pendingSegment.removeAll(keepingCapacity: true)
        segmentStart = nil
        vad.reset()
    }

    public func setSTT(_ engine: STTEngine) {
        self.stt = engine
    }

    public func openConversationWindow() async {
        await wake.openWindow()
        if case .open(let until) = await wake.state {
            outputsContinuation.yield(.windowOpened(until: until))
        }
    }

    public func closeConversationWindow() async {
        await wake.closeWindow()
        outputsContinuation.yield(.windowClosed(reason: "manual"))
    }

    // MARK: - Internal

    private func pumpLoop() async {
        let frameSamples = (config.sampleRate * config.frameMs) / 1000
        let maxSegmentSamples = Int(config.maxSegmentS * Double(config.sampleRate))

        while !Task.isCancelled {
            let chunk = await source.nextFrame(maxSamples: frameSamples)
            if chunk.isEmpty {
                try? await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            let now = Date()
            let transition = vad.ingest(samples: chunk, at: now)

            if vad.inSpeech || transition == .speechStart(at: now) {
                pendingSegment.append(contentsOf: chunk)
                if segmentStart == nil { segmentStart = now }

                if pendingSegment.count >= maxSegmentSamples {
                    await flushSegment(forceEnd: true)
                }
            }

            switch transition {
            case .speechStart(let at):
                segmentStart = at
                await logBus.publish(.vadSegment(startMs: at.timeIntervalSince1970 * 1000,
                                                 endMs: 0))
            case .speechEnd:
                await flushSegment(forceEnd: false)
            case nil:
                break
            }
        }
    }

    /// Closes the current pending segment and hands it to a background
    /// STT task. Returns immediately. The pump must NEVER await this
    /// directly — STT typically takes 500–2000 ms, and during that
    /// window audio keeps arriving in the ring buffer; if the pump is
    /// blocked we miss the user's next utterance and process Rocky's
    /// TTS echo instead.
    private func flushSegment(forceEnd: Bool) async {
        guard !pendingSegment.isEmpty else { return }
        let segment = pendingSegment
        let started = segmentStart ?? Date()
        pendingSegment.removeAll(keepingCapacity: true)
        segmentStart = nil
        if forceEnd { vad.reset() }

        // Single in-flight STT. If one is already running, drop this
        // segment. Latest user audio matters more than backed-up
        // history; queueing turns N segments into N × 1.5 s of latency.
        if sttTask != nil {
            await logBus.publish(.sidecarLog(
                sidecar: "voice", level: .info,
                message: "stt busy — dropped \(segment.count) samples",
                fields: [:]
            ))
            return
        }

        sttTask = Task { [weak self] in
            await self?.runSTT(segment: segment, started: started)
        }
    }

    private func runSTT(segment: [Float], started: Date) async {
        defer { sttTask = nil }
        if Task.isCancelled { return }
        do {
            let transcript = try await stt.transcribe(
                samples: segment, at: config.sampleRate
            )
            if Task.isCancelled { return }
            let totalMs = Date().timeIntervalSince(started) * 1000
            await logBus.publish(.sttFinal(text: transcript.text, totalMs: totalMs))
            await dispatchFinal(transcript.text)
        } catch {
            await logBus.publish(.error(
                scope: "stt", message: "\(error)", recoverable: true
            ))
        }
    }

    private func dispatchFinal(_ text: String) async {
        let decision = await wake.decide(transcript: text)
        switch decision {
        case .dispatch(let transcript, let reason):
            outputsContinuation.yield(.finalText(text: transcript, dispatched: true, reason: reason))
            // Surface the (re)opened window to AppServices so its
            // `conversationOpenUntil` mirror tracks the wake filter and
            // schedule the idle-close timer for the new deadline.
            if case .open(let until) = await wake.state {
                outputsContinuation.yield(.windowOpened(until: until))
                scheduleIdleClose(at: until)
            }
            switch reason {
            case .wakeMatch(let name):
                await logBus.publish(.wakeMatch(name: name, transcript: transcript))
                await logBus.publish(.conversationWindow(transition: .opened, reason: "wake"))
            case .withinWindow:
                await logBus.publish(.conversationWindow(transition: .extended, reason: "follow-up"))
            }
        case .ignore:
            outputsContinuation.yield(.finalText(text: text, dispatched: false, reason: nil))
        case .close(let reason):
            windowCloseTask?.cancel()
            windowCloseTask = nil
            outputsContinuation.yield(.windowClosed(reason: reason))
            await logBus.publish(.conversationWindow(transition: .closed, reason: reason))
        }
    }

    private func scheduleIdleClose(at deadline: Date) {
        windowCloseTask?.cancel()
        windowCloseTask = Task { [weak self] in
            let secs = deadline.timeIntervalSinceNow
            if secs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            }
            if Task.isCancelled { return }
            await self?.fireIdleClose()
        }
    }

    private func fireIdleClose() async {
        // Only act if the wake filter is still in the open state we
        // armed for — a follow-up dispatch will have rescheduled its
        // own task already.
        guard case .open = await wake.state else { return }
        await wake.closeWindow()
        outputsContinuation.yield(.windowClosed(reason: "idle timeout"))
        await logBus.publish(.conversationWindow(transition: .closed, reason: "idle"))
    }
}
