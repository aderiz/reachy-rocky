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
        /// A final transcript. Carries enough metadata for the
        /// downstream `AddressFilter` to score the audio segment
        /// the transcript came from (without re-running STT or
        /// re-reading the ring buffer):
        ///   - `dispatched`: `true` if the WakeFilter ADMITTED it
        ///     (wake-match OR within-window). The address filter
        ///     then makes the actual brain-dispatch call.
        ///   - `reason`: what the WakeFilter decided.
        ///   - `confidence`: STT confidence in [0, 1]. 1.0 for
        ///     MLX-Whisper / WhisperKit; varies on Apple Speech.
        ///   - `peakRMS` / `meanRMS`: loudness statistics over the
        ///     captured segment (after VAD trim, before STT).
        case finalText(
            text: String,
            dispatched: Bool,
            reason: WakeFilter.Reason?,
            confidence: Double,
            peakRMS: Double,
            meanRMS: Double
        )
        case windowOpened(until: Date)
        case windowClosed(reason: String)
    }

    private let source: AudioFrameSource
    private var stt: STTEngine
    private let wake: WakeFilter
    private let logBus: LogBus
    public private(set) var config: Config
    private var vad: any VAD
    private var pendingSegment: [Float] = []
    private var segmentStart: Date?
    /// Rolling buffer of the last few audio frames. Prepended to
    /// `pendingSegment` when the VAD's `.speechStart` transition
    /// fires, so the first ~90 ms of speech (which the VAD needed
    /// to confirm `minSpeechFrames` consecutive loud frames before
    /// transitioning) isn't lost. Without this, every utterance
    /// has its leading plosive/fricative clipped — turning
    /// "Rocky" into "ocky", which Apple Speech often transcribes
    /// as "okay" / "hockey" / "key" and the wake filter misses.
    private var preRoll: [Float] = []
    /// One queued segment that's still waiting for STT to free up.
    /// Single slot — replaces the previous "drop new" behaviour
    /// that ate every other utterance during a fast back-and-forth.
    private var queuedSegment: (samples: [Float], started: Date)?
    private var pumpTask: Task<Void, Never>?
    /// In-flight STT task. The pump never awaits transcription directly —
    /// it spawns this task and continues draining frames. If a second
    /// speechEnd arrives while one is in-flight we drop the segment
    /// rather than queueing (latest user audio matters more than backed-
    /// up history, and queueing turns into a multi-second stall).
    private var sttTask: Task<Void, Never>?
    /// Speculative STT task: fired at the VAD's silence-midway point
    /// (half-way through the silence accumulation phase) against a
    /// snapshot of `pendingSegment`. By the time firm speech-end
    /// arrives, the transcript is often already in. Cancelled if
    /// the user resumes speaking (quietFrameCount drops back to 0)
    /// — in that case the speculative result is on a clipped
    /// segment and we fall back to a fresh STT against the full
    /// extended segment.
    private var speculativeSttTask: Task<Transcript?, Never>?
    /// True after we've fired the speculative task for the current
    /// silence phase, so we don't re-fire on every subsequent silent
    /// frame in the same phase. Reset on speechStart and speechEnd.
    private var speculativeFiredThisPhase: Bool = false
    /// Fires `.windowClosed` when the wake-filter conversation window
    /// hits its deadline without an extending follow-up. Cancelled and
    /// rescheduled on every dispatch so the timer always reflects the
    /// latest deadline.
    private var windowCloseTask: Task<Void, Never>?

    /// Dedup state: normalised text + timestamp of the most recently
    /// `.dispatch`-decided transcript. Used to suppress duplicate
    /// dispatches when VAD over-segments a single utterance into two
    /// near-identical transcripts (typical on the robot-mic WebRTC
    /// path, where the audio track has occasional silent gaps that
    /// EnergyVAD interprets as speech-end).
    private var lastDispatchedNormalized: String = ""
    private var lastDispatchedAt: Date = .distantPast
    /// How long a "same as just-dispatched" transcript is treated as
    /// a VAD double-fire. Tight enough that a genuine repeat ("Rocky
    /// what's this? ... Rocky what's this?") with 3 + seconds between
    /// them still goes through both times.
    private let dedupWindowS: TimeInterval = 3.0

    public nonisolated let outputs: AsyncStream<Output>
    private let outputsContinuation: AsyncStream<Output>.Continuation

    public init(
        source: AudioFrameSource,
        stt: STTEngine,
        wake: WakeFilter,
        logBus: LogBus,
        config: Config = Config(),
        vad: any VAD = EnergyVAD()
    ) {
        self.source = source
        self.stt = stt
        self.wake = wake
        self.logBus = logBus
        self.config = config
        self.vad = vad
        var c: AsyncStream<Output>.Continuation!
        // Unbounded buffer — this stream carries sequence-sensitive
        // state events (`.windowOpened` / `.windowClosed`)
        // alongside transcript events. A `.bufferingNewest`
        // policy could drop a `.windowClosed` while delivering
        // a later `.windowOpened`, leaving AppServices'
        // `conversationOpenUntil` mirror inconsistent with the
        // wake filter's actual state. Volumes are low (a few
        // events per turn); unbounded is safe.
        self.outputs = AsyncStream<Output>(
            bufferingPolicy: .unbounded
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
        speculativeSttTask?.cancel()
        speculativeSttTask = nil
        speculativeFiredThisPhase = false
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

    /// Live-update the VAD's RMS threshold. Called by AppServices
    /// after the user runs the calibration flow or moves the
    /// sensitivity slider. Threshold change takes effect on the
    /// very next frame; the in-flight VAD state (loud/quiet frame
    /// counters) is preserved so a re-tune mid-utterance doesn't
    /// drop the user's speech segment.
    ///
    /// Only applies to `EnergyVAD` — the threshold semantics differ
    /// across implementations (RMS [0.001, 0.05] for Energy vs.
    /// probability [0, 1] for Silero), so the calibration UI's
    /// `setVADThreshold` is wired specifically for the energy scale
    /// and is hidden when Silero is the active engine. (M3+
    /// follow-up: a Silero-aware calibration that sets a probability
    /// threshold instead.)
    public func setVADThreshold(_ rms: Float) {
        if var ev = vad as? EnergyVAD {
            ev.config.rmsThreshold = rms
            vad = ev
        }
    }

    /// Snapshot of the current VAD threshold. Useful for the
    /// calibration UI to show the current value before/after.
    /// Returns the EnergyVAD threshold if the active engine is
    /// energy; for Silero it returns the configured probability
    /// threshold (0..1). The UI can switch its slider range based
    /// on the active engine.
    public func currentVADThreshold() -> Float {
        if let ev = vad as? EnergyVAD {
            return ev.config.rmsThreshold
        }
        if let sv = vad as? SileroVAD {
            return sv.config.threshold
        }
        return 0
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
        // Pre-roll buffer holds enough audio to cover the VAD's
        // confirmation latency (`minSpeechFrames` × frameMs). 6
        // frames at 30 ms = 180 ms, comfortably more than the
        // ~90 ms VAD onset window. Larger doesn't hurt — the
        // buffer is cheap and only flushed forward on .speechStart.
        let preRollFrames = 6
        let preRollSamples = preRollFrames * frameSamples

        while !Task.isCancelled {
            let chunk = await source.nextFrame(maxSamples: frameSamples)
            if chunk.isEmpty {
                try? await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            let now = Date()
            let transition = vad.ingest(samples: chunk, at: now)

            if vad.inSpeech || transition == .speechStart(at: now) {
                // First frame of a new speech segment — flush the
                // pre-roll buffer ahead of the chunk so the start
                // of "Rocky" isn't lost to VAD onset latency.
                if pendingSegment.isEmpty, !preRoll.isEmpty {
                    pendingSegment.append(contentsOf: preRoll)
                }
                pendingSegment.append(contentsOf: chunk)
                if segmentStart == nil { segmentStart = now }

                if pendingSegment.count >= maxSegmentSamples {
                    await flushSegment(forceEnd: true)
                }
            } else {
                // Not in speech — keep this frame in the rolling
                // pre-roll. Drop oldest to maintain capacity.
                preRoll.append(contentsOf: chunk)
                if preRoll.count > preRollSamples {
                    preRoll.removeFirst(preRoll.count - preRollSamples)
                }
            }

            // Speculative-STT triggers, evaluated after the VAD has
            // ingested this frame so quietFrameCount reflects the
            // up-to-date silence accumulation.
            await maybeFireSpeculative()
            maybeCancelSpeculativeOnResume()

            switch transition {
            case .speechStart(let at):
                segmentStart = at
                speculativeFiredThisPhase = false
                await logBus.publish(.vadSegment(startMs: at.timeIntervalSince1970 * 1000,
                                                 endMs: 0))
            case .speechEnd:
                await flushSegment(forceEnd: false)
                speculativeFiredThisPhase = false
                // Pre-roll is consumed once a segment ends — start
                // the next pre-roll fresh so we don't include
                // tail audio from the previous utterance.
                preRoll.removeAll(keepingCapacity: true)
            case nil:
                break
            }
        }
    }

    /// Fire a speculative STT against the current segment when the
    /// VAD's quietFrameCount hits its midway threshold. By the time
    /// firm speech-end arrives, the transcript is often already in
    /// — saving ~150–300 ms of wallclock per utterance on the happy
    /// path (user stops talking and stays stopped).
    private func maybeFireSpeculative() async {
        guard !speculativeFiredThisPhase,
              speculativeSttTask == nil,
              sttTask == nil,
              !pendingSegment.isEmpty,
              vad.inSpeech,
              vad.quietFrameCount >= vad.silenceMidwayCount
        else { return }
        let snapshot = pendingSegment
        let rate = config.sampleRate
        let engine = stt
        speculativeFiredThisPhase = true
        speculativeSttTask = Task<Transcript?, Never> { [weak self] in
            do {
                let t = try await engine.transcribe(samples: snapshot, at: rate)
                if Task.isCancelled { return nil }
                return t
            } catch {
                await self?.logBus.publish(.error(
                    scope: "stt.speculative", message: "\(error)",
                    recoverable: true
                ))
                return nil
            }
        }
        await logBus.publish(.sidecarLog(
            sidecar: "voice", level: .debug,
            message: "stt: speculative fired at \(snapshot.count) samples",
            fields: [:]
        ))
    }

    /// If the user resumes speaking during the silence-accumulation
    /// phase, `quietFrameCount` drops back to 0 — that's our signal
    /// that the speculative segment is now stale (it's a prefix of
    /// what the full utterance will turn out to be). Cancel so we
    /// don't waste cycles producing a transcript we'll throw away.
    private func maybeCancelSpeculativeOnResume() {
        guard let task = speculativeSttTask else { return }
        // quietFrameCount > 0 means we're still in (or just entered)
        // a silence run. Only zero counts as "resumed speaking".
        if vad.quietFrameCount == 0 {
            task.cancel()
            speculativeSttTask = nil
            speculativeFiredThisPhase = false
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
        // Don't reset the VAD on a force-end. The previous code
        // did, which forced `inSpeech` back to false and required
        // another `minSpeechFrames` of accumulation before the
        // next frame would be captured — re-introducing the C1
        // dropout mid-utterance every time the segment cap was
        // hit. The user is still talking; treat the cap as an
        // artificial slice, not a real silence event. The pump
        // continues feeding `pendingSegment` from the very next
        // frame because `vad.inSpeech` stays true.
        _ = forceEnd

        // Compute peak / mean RMS for the captured segment. Cheap
        // (single pass) and gives the downstream AddressFilter a
        // loudness measurement without re-reading the ring buffer.
        let (peakRMS, meanRMS) = Self.computeRMS(segment)

        // STT is single-in-flight (Apple Speech doesn't pipeline a
        // second request well). Earlier behaviour was "drop new
        // segment if STT is busy", which silently ate every other
        // utterance during a fast back-and-forth — the user said
        // "Rocky" then "what time is it" 400 ms later, the second
        // segment was dropped, and Rocky responded to just "Rocky"
        // with a generic acknowledgement.
        //
        // New behaviour: keep one queued segment. If a third
        // arrives while the first is still in flight, the second
        // (queued) is replaced — under sustained pressure we'd
        // rather process the most recent utterance than a stale
        // one. When the in-flight STT finishes, the queued
        // segment is dispatched immediately.
        if sttTask != nil {
            queuedSegment = (samples: segment, started: started)
            await logBus.publish(.sidecarLog(
                sidecar: "voice", level: .debug,
                message: "stt busy — queued \(segment.count) samples",
                fields: [:]
            ))
            return
        }

        // Speculative path: a previously-fired STT may already have
        // (or be about to deliver) a transcript for a prefix of this
        // segment. Use it if available, but fall back to a fresh STT
        // if the speculative returned empty (Whisper's no-speech gate
        // can fire mid-utterance) — the full segment may still
        // transcribe successfully.
        if let spec = speculativeSttTask {
            speculativeSttTask = nil
            sttTask = Task { [weak self] in
                await self?.runSpeculativeOrFallback(
                    speculative: spec,
                    segment: segment, started: started,
                    peakRMS: peakRMS, meanRMS: meanRMS
                )
            }
            return
        }

        sttTask = Task { [weak self] in
            await self?.runSTT(
                segment: segment, started: started,
                peakRMS: peakRMS, meanRMS: meanRMS
            )
        }
    }

    /// Await the speculative task. If it returned a non-empty
    /// transcript, dispatch it with the FULL segment's RMS metrics
    /// (so the AddressFilter still scores against the complete
    /// audio segment, not the speculative prefix). If empty or
    /// cancelled, fall through to a fresh full-segment STT.
    private func runSpeculativeOrFallback(
        speculative: Task<Transcript?, Never>,
        segment: [Float], started: Date,
        peakRMS: Double, meanRMS: Double
    ) async {
        if Task.isCancelled { sttTask = nil; drainQueueIfAny(); return }
        let started_local = Date()
        let result = await speculative.value
        let totalMs = Date().timeIntervalSince(started_local) * 1000
        if let r = result, !r.text.isEmpty {
            await logBus.publish(.sttFinal(text: r.text, totalMs: totalMs))
            await dispatchFinal(
                r.text,
                confidence: r.confidence,
                peakRMS: peakRMS, meanRMS: meanRMS
            )
            sttTask = nil
            drainQueueIfAny()
            return
        }
        // Fall back: speculative produced nothing usable (cancelled,
        // empty, or no-speech-gated by the sidecar). Run fresh STT
        // on the full segment.
        await runSTT(
            segment: segment, started: started,
            peakRMS: peakRMS, meanRMS: meanRMS
        )
    }

    /// Extracted from `runSTT` so both the speculative and direct
    /// paths can kick the queued segment forward after they finish.
    private func drainQueueIfAny() {
        guard let next = queuedSegment else { return }
        queuedSegment = nil
        let (np, nm) = Self.computeRMS(next.samples)
        sttTask = Task { [weak self] in
            await self?.runSTT(
                segment: next.samples, started: next.started,
                peakRMS: np, meanRMS: nm
            )
        }
    }

    /// Single-pass peak + mean RMS over a float32 PCM segment.
    /// "Peak RMS" here is the loudest 30 ms window — gives us a
    /// number that survives transient silence at the segment's
    /// edges while still penalising mostly-quiet utterances.
    private static func computeRMS(_ samples: [Float]) -> (peak: Double, mean: Double) {
        guard !samples.isEmpty else { return (0, 0) }
        var sumSq: Double = 0
        var peak: Double = 0
        // 30 ms windows at 16 kHz = 480 samples. Cheap rolling
        // window — accumulate sum-of-squares, subtract the leaving
        // sample, divide and sqrt at each step.
        let windowSize = 480
        var winSq: Double = 0
        for (i, s) in samples.enumerated() {
            let sq = Double(s) * Double(s)
            sumSq += sq
            winSq += sq
            if i >= windowSize {
                let leaving = Double(samples[i - windowSize])
                winSq -= leaving * leaving
            }
            let denom = Double(min(i + 1, windowSize))
            let rms = (winSq / denom).squareRoot()
            if rms > peak { peak = rms }
        }
        let mean = (sumSq / Double(samples.count)).squareRoot()
        return (peak, mean)
    }

    private func runSTT(
        segment: [Float], started: Date,
        peakRMS: Double, meanRMS: Double
    ) async {
        if Task.isCancelled { sttTask = nil; return }
        do {
            // Inference-only timing. `started` was set to `segmentStart`
            // (when speech began) — measuring from there conflates the
            // speech duration into "STT cost" and was producing
            // 2000–23000 ms values in profiles. Anchor here, just before
            // the transcribe call, so `totalMs` reflects only the engine
            // work the user is actually waiting on.
            let inferenceStart = Date()
            let transcript = try await stt.transcribe(
                samples: segment, at: config.sampleRate
            )
            if Task.isCancelled { sttTask = nil; return }
            let totalMs = Date().timeIntervalSince(inferenceStart) * 1000
            _ = started // kept for parity with previous signature; not used in totalMs
            await logBus.publish(.sttFinal(text: transcript.text, totalMs: totalMs))
            await dispatchFinal(
                transcript.text,
                confidence: transcript.confidence,
                peakRMS: peakRMS,
                meanRMS: meanRMS
            )
        } catch {
            await logBus.publish(.error(
                scope: "stt", message: "\(error)", recoverable: true
            ))
        }
        sttTask = nil

        // Drain any segment that arrived while we were busy.
        drainQueueIfAny()
    }

    private func dispatchFinal(
        _ text: String,
        confidence: Double,
        peakRMS: Double,
        meanRMS: Double
    ) async {
        let decision = await wake.decide(transcript: text)
        switch decision {
        case .dispatch(let transcript, let reason):
            // Dedup gate: VAD on the robot-mic WebRTC path
            // occasionally splits one utterance into two segments
            // because of brief silent gaps in the audio stream.
            // Each segment is STT'd separately and produces a
            // near-identical transcript a fraction of a second
            // apart. Suppress the second one so the brain only
            // sees one prompt per spoken sentence. The normalisation
            // strips case and non-alphanumeric chars so "Rocky
            // what's this" and "Rocky, what's this?" collapse to
            // the same key.
            let normalized = Self.normalizeForDedup(transcript)
            let now = Date()
            let withinWindow = now.timeIntervalSince(lastDispatchedAt) < dedupWindowS
            if withinWindow, !normalized.isEmpty, normalized == lastDispatchedNormalized {
                await logBus.publish(.sidecarLog(
                    sidecar: "voice", level: .info,
                    message: "dedup: dropping duplicate \"\(transcript)\"",
                    fields: ["normalized": normalized,
                             "since_last_ms": "\(Int(now.timeIntervalSince(lastDispatchedAt) * 1000))"]
                ))
                outputsContinuation.yield(.finalText(
                    text: text, dispatched: false, reason: nil,
                    confidence: confidence, peakRMS: peakRMS, meanRMS: meanRMS
                ))
                return
            }
            lastDispatchedNormalized = normalized
            lastDispatchedAt = now

            outputsContinuation.yield(.finalText(
                text: transcript, dispatched: true, reason: reason,
                confidence: confidence, peakRMS: peakRMS, meanRMS: meanRMS
            ))
            // Surface the (re)opened window to AppServices so its
            // `conversationOpenUntil` mirror tracks the wake filter
            // and schedule the idle-close timer for the new deadline.
            // The WakeFilter no longer auto-extends on .withinWindow
            // — only wake-match opens the window here. Engaged
            // extensions are driven by AppServices calling
            // `wake.extendOnEngaged()` after AddressFilter accepts.
            if case .open(let until) = await wake.state {
                outputsContinuation.yield(.windowOpened(until: until))
                scheduleIdleClose(at: until)
            }
            switch reason {
            case .wakeMatch(let name):
                await logBus.publish(.wakeMatch(name: name, transcript: transcript))
                await logBus.publish(.conversationWindow(transition: .opened, reason: "wake"))
            case .withinWindow:
                // No conversation-window event here — only emit
                // "extended" later, when AddressFilter signals
                // engaged dispatch and the window is actually
                // refreshed.
                break
            }
        case .ignore:
            outputsContinuation.yield(.finalText(
                text: text, dispatched: false, reason: nil,
                confidence: confidence, peakRMS: peakRMS, meanRMS: meanRMS
            ))
        case .close(let reason):
            windowCloseTask?.cancel()
            windowCloseTask = nil
            outputsContinuation.yield(.windowClosed(reason: reason))
            await logBus.publish(.conversationWindow(transition: .closed, reason: reason))
        }
    }

    /// Normalise a transcript for the dedup comparison: lowercased,
    /// punctuation stripped, runs of whitespace collapsed. Picks up
    /// "Rocky what's this" ≡ "Rocky, what's this?" but keeps genuinely
    /// different transcripts ("what time is it" vs "what time was it")
    /// distinct.
    private static func normalizeForDedup(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let scalars = text.unicodeScalars.filter { allowed.contains($0) }
        let lowered = String(String.UnicodeScalarView(scalars)).lowercased()
        return lowered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
