import Foundation
import Telemetry

/// `StreamingTTS` is now a thin echo-gate coordinator.
///
/// Its only job is to publish `isSpeaking` on an `AsyncStream<Bool>`
/// so the rest of the app knows when Rocky's voice is on the speaker
/// and STT should mute. The previous responsibilities — accumulating
/// PCM chunks, building WAVs, chunked uploads, paced multi-clip
/// playback — were removed. They turned a 1.5 s synth+play pipeline
/// into a 10 s wait by sleeping for the full audio duration before
/// returning. `RobotTTS.speak()` now handles synth/upload/play_sound
/// directly and calls `signalSpeaking(durationS:)` here to engage the
/// echo gate without blocking.
///
/// Lifecycle for one `speak()`:
///   1. `RobotTTS.speak()` calls `signalSpeaking(durationS:)` after
///      `play_sound` fires.
///   2. `isSpeaking` flips `true` immediately. A detached timer is
///      armed for `durationS + sttPostRollS` (~audio play time).
///   3. When the timer fires AND no later `signalSpeaking` has been
///      issued, `isSpeaking` flips `false`. If another call has come
///      in meanwhile, the stale timer is a no-op.
///
/// `cancelSpeaking()` flips the flag down right now (used by the
/// `cancel` / `stopSound` path).
public actor StreamingTTS {
    public nonisolated let isSpeakingStream: AsyncStream<Bool>
    private let isSpeakingContinuation: AsyncStream<Bool>.Continuation
    private(set) public var isSpeaking: Bool = false

    /// Tail (post-last-chunk) for the echo gate. STT keeps processing
    /// audio briefly after the speaker stops; this widens the busy
    /// window so Rocky doesn't transcribe his own decay.
    public private(set) var sttPostRollS: Double = 0.5

    /// Monotonic id assigned to each `signalSpeaking` call. The
    /// detached timer captures the id at arming time and only flips
    /// `isSpeaking` false if it's still the latest. Without this, a
    /// short utterance's timer could clear the flag mid-way through
    /// a subsequent longer utterance.
    private var speakingSeq: UInt64 = 0

    /// Volume mirror so the slider drives both this and `RobotTTS`.
    /// Read by `RobotTTS.scaleWavVolume`; left here so the existing
    /// setter wiring keeps working.
    public private(set) var volume: Double = 1.0

    private let logBus: LogBus

    public init(logBus: LogBus) {
        self.logBus = logBus
        var c: AsyncStream<Bool>.Continuation!
        self.isSpeakingStream = AsyncStream<Bool>(
            bufferingPolicy: .bufferingNewest(8)
        ) { cont in c = cont }
        self.isSpeakingContinuation = c
    }

    public func setSttPostRoll(_ seconds: Double) {
        self.sttPostRollS = max(0, seconds)
    }

    public func setVolume(_ v: Double) {
        self.volume = max(0.0, min(3.0, v))
    }

    /// Engage the echo gate for `durationS + sttPostRollS` seconds.
    /// Returns immediately; the auto-clear happens on a detached task.
    /// Multiple overlapping calls collapse to the last one (only the
    /// most recent timer flips the flag off).
    public func signalSpeaking(durationS: Double) {
        speakingSeq &+= 1
        let mySeq = speakingSeq
        setSpeaking(true)
        let total = max(0.0, durationS) + sttPostRollS
        Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(total * 1_000_000_000)
            )
            guard let self else { return }
            await self.maybeClearSpeaking(forSeq: mySeq)
        }
    }

    /// Force-clear the echo gate now. Used by `cancel` /
    /// `stopSound` so the user can resume speaking immediately when
    /// they interrupt a reply.
    public func cancelSpeaking() {
        speakingSeq &+= 1  // invalidate any pending auto-clear
        setSpeaking(false)
    }

    /// Called by the detached auto-clear task. Drops the flag only
    /// if no later `signalSpeaking` has bumped the sequence.
    private func maybeClearSpeaking(forSeq seq: UInt64) {
        if seq == speakingSeq { setSpeaking(false) }
    }

    private func setSpeaking(_ value: Bool) {
        if value == isSpeaking { return }
        isSpeaking = value
        isSpeakingContinuation.yield(value)
    }
}
