import Foundation

/// Strict "is this speech addressed to Rocky?" filter that sits
/// between STT output and the brain dispatch.
///
/// The v0.x pipeline gated voice-to-brain on a single signal: "did
/// the VAD think there was speech?". That accepts background TV,
/// other people's conversations, and Whisper hallucinations — none
/// of which the user actually said *to* Rocky.
///
/// AddressFilter applies the human-conversational heuristic:
/// **respond when spoken to, ignore background.** Each transcript is
/// evaluated against multiple signals (loudness over background,
/// direction-of-arrival from the robot mic array, face engagement,
/// STT confidence, junk-phrase list, wake-word match) and dispatched
/// only when the evidence supports direct address.
///
/// The rule order is deliberate — each gate either short-circuits or
/// contributes a labelled reason that's surfaced via
/// `TelemetryEvent.addressFilterAccept` / `.addressFilterDrop` so the
/// user can see *why* a transcript was dropped in the Logs view.
///
/// Strict mode (user-selected): when in doubt, drop. The wake word
/// is always honoured (it's the user explicitly addressing Rocky), so
/// the bot remains reachable in ambiguous conditions (camera off, Mac
/// mic with no DoA, etc.).
public actor AddressFilter {

    // MARK: - Configuration

    /// Tunable knobs. All defaults match the SettingsStore defaults
    /// and are re-applied at runtime via `setConfig(_:)` whenever the
    /// user adjusts them (calibration commit, settings slider, etc.).
    public struct Config: Sendable, Equatable {
        public var enabled: Bool
        public var minSttConfidence: Double
        public var rmsFloor: Double
        public var loudnessRatio: Double
        public var userDoaCenterRad: Double
        public var userDoaToleranceRad: Double
        public var faceEngageWindowS: TimeInterval
        public var junkPhrases: [String]
        public var verbPrefixes: [String]
        public var confidenceBypass: [String]

        public init(
            enabled: Bool = true,
            minSttConfidence: Double = 0.35,
            rmsFloor: Double = 0.012,
            loudnessRatio: Double = 4.0,
            userDoaCenterRad: Double = 0,
            userDoaToleranceRad: Double = 0.45,
            faceEngageWindowS: TimeInterval = 3.0,
            junkPhrases: [String] = [
                "thank you", "thanks", "you", "bye", "okay", ".", "..."
            ],
            verbPrefixes: [String] = [
                "what", "where", "when", "why", "how", "tell",
                "show", "do", "does", "can", "could", "is", "are",
                "play", "stop", "set", "turn"
            ],
            confidenceBypass: [String] = [
                "yes", "no", "stop", "wait", "cancel"
            ]
        ) {
            self.enabled = enabled
            self.minSttConfidence = minSttConfidence
            self.rmsFloor = rmsFloor
            self.loudnessRatio = loudnessRatio
            self.userDoaCenterRad = userDoaCenterRad
            self.userDoaToleranceRad = userDoaToleranceRad
            self.faceEngageWindowS = faceEngageWindowS
            self.junkPhrases = junkPhrases
            self.verbPrefixes = verbPrefixes
            self.confidenceBypass = confidenceBypass
        }
    }

    // MARK: - Inputs

    /// Bundle of signals the filter consults for one dispatch
    /// decision. Snapshots are captured at the call site
    /// (`AppServices.handleVoice`) so the actor doesn't have to reach
    /// back into the rest of the app.
    public struct Signals: Sendable {
        /// The candidate transcript text. Already passed STT.
        public var text: String
        /// STT confidence in [0, 1]. Apple Speech reports per-utterance;
        /// MLX-Whisper / WhisperKit currently always emit 1.0.
        public var sttConfidence: Double
        /// Peak RMS over the captured speech segment.
        public var segmentPeakRMS: Double
        /// Mean RMS over the captured speech segment. Together with
        /// peak, gives the filter a sense of "loud burst" vs.
        /// "sustained quiet hum".
        public var segmentMeanRMS: Double
        /// Estimated room noise ceiling — calibration's noise P99.
        /// Used as the denominator of the loudness ratio.
        public var roomNoiseCeiling: Double
        /// Direction-of-arrival angle from the robot mic array
        /// (radians, 0 = front). Nil when the active mic source is
        /// the Mac (no array → no DoA).
        public var doaRad: Double?
        /// Robot-side VAD speech flag corroborating DoA. Nil when
        /// using the Mac mic.
        public var doaIsSpeech: Bool?
        /// Age of the most recent face detection (seconds since
        /// `lastFaceDetectionAt`). Nil if a face has never been seen
        /// since launch. The filter treats this as "no recent
        /// engagement", which is distinct from "definitely no face"
        /// — both are non-positive signals but for slightly different
        /// reasons.
        public var faceVisibleAgeS: TimeInterval?
        /// Whether the wake filter decided this transcript should
        /// even be considered (`.wakeMatch` or `.withinWindow`).
        public var wakeReason: WakeFilter.Reason
        /// Whether Rocky is currently producing TTS (or within the
        /// 1.5 s tail). Triggers the echo gate.
        public var ttsActive: Bool
        /// Active mic source ("mac" or "robot"). Drives whether DoA
        /// gates are evaluated at all.
        public var micSource: String

        public init(
            text: String,
            sttConfidence: Double,
            segmentPeakRMS: Double,
            segmentMeanRMS: Double,
            roomNoiseCeiling: Double,
            doaRad: Double?,
            doaIsSpeech: Bool?,
            faceVisibleAgeS: TimeInterval?,
            wakeReason: WakeFilter.Reason,
            ttsActive: Bool,
            micSource: String
        ) {
            self.text = text
            self.sttConfidence = sttConfidence
            self.segmentPeakRMS = segmentPeakRMS
            self.segmentMeanRMS = segmentMeanRMS
            self.roomNoiseCeiling = roomNoiseCeiling
            self.doaRad = doaRad
            self.doaIsSpeech = doaIsSpeech
            self.faceVisibleAgeS = faceVisibleAgeS
            self.wakeReason = wakeReason
            self.ttsActive = ttsActive
            self.micSource = micSource
        }
    }

    // MARK: - Output

    public enum Decision: Sendable, Equatable {
        /// Accept and dispatch to the brain. `engaged` is true when
        /// the decision relied on real engagement evidence (loud +
        /// direct + face/verb). The caller uses this to decide
        /// whether to extend the conversation window — pure
        /// "withinWindow" dispatches without engagement don't extend.
        case dispatch(score: Double, reasons: [String], engaged: Bool)
        /// Drop the transcript. Carries the list of reasons so the
        /// user can debug in Logs (e.g., `["low_loudness", "no_face",
        /// "doa_off_axis"]`).
        case drop(score: Double, reasons: [String])
    }

    // MARK: - State

    private var config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    public func setConfig(_ newConfig: Config) {
        self.config = newConfig
    }

    public func currentConfig() -> Config { config }

    // MARK: - Decision

    public func decide(_ signals: Signals) -> Decision {
        // 0. Master switch: when disabled, the filter is transparent
        //    — accepts everything that reached it (the WakeFilter
        //    still applies upstream). This is the v0.x behaviour.
        if !config.enabled {
            return .dispatch(score: 1.0, reasons: ["filter_disabled"], engaged: false)
        }

        let normalised = AddressFilter.normalise(signals.text)

        // 1. Echo gate: Rocky is talking → it's almost certainly his
        //    own bleed. Drop unconditionally.
        if signals.ttsActive {
            return .drop(score: 0, reasons: ["echo_tail"])
        }

        // 2. Wake-name match wins — *if* the audio that produced it
        //    actually had enough energy to be real speech. STT can
        //    hallucinate "rocky" on near-silent segments, and the
        //    wake path is the one path nothing else gates, so a
        //    hallucinated wake can wake Rocky unexpectedly. Require
        //    segment peak RMS ≥ the calibrated floor so silence-
        //    driven hallucinations can't sneak through. A real user
        //    shouting "Rocky!" easily clears this; a Whisper
        //    confabulation on an empty room won't.
        if case .wakeMatch = signals.wakeReason {
            if signals.segmentPeakRMS < config.rmsFloor {
                return .drop(score: 0,
                             reasons: ["wake_hallucination", "low_loudness"])
            }
            return .dispatch(score: 1.0, reasons: ["wake"], engaged: true)
        }

        // 3. Confidence floor (only meaningful on Apple Speech today).
        //    A short bypass set still passes — "yes/no/stop/wait" are
        //    important and routinely log lower confidence.
        let isShortBypass = config.confidenceBypass.contains(normalised)
        if !isShortBypass && signals.sttConfidence < config.minSttConfidence {
            return .drop(score: 0.1, reasons: ["low_confidence"])
        }

        // 4. Junk-phrase deny-list. These are the well-known Whisper
        //    / Apple Speech hallucinations on silence. Apple often
        //    reports them at confidence 1.0, so the confidence gate
        //    above doesn't catch them — the deny-list does.
        if config.junkPhrases.contains(normalised) {
            return .drop(score: 0, reasons: ["junk_phrase"])
        }

        // 5. Scored gates. Each adds a reason (positive or negative).
        var positive: [String] = []
        var negative: [String] = []

        // 5a. Loudness over background.
        let ratio: Double
        if signals.roomNoiseCeiling > 1e-6 {
            ratio = signals.segmentPeakRMS / signals.roomNoiseCeiling
        } else {
            ratio = signals.segmentPeakRMS / max(config.rmsFloor, 1e-6)
        }
        let loudEnough = signals.segmentPeakRMS >= config.rmsFloor
                      && ratio >= config.loudnessRatio
        if loudEnough { positive.append("loud") }
        else { negative.append("low_loudness") }

        // 5b. Direction of arrival — robot-mic only.
        let doaOnAxis: Bool
        if signals.micSource == "robot", let doa = signals.doaRad {
            let delta = AddressFilter.shortestAngle(
                doa, signals.userDoaCenterRad ?? config.userDoaCenterRad
            )
            doaOnAxis = abs(delta) <= config.userDoaToleranceRad
            if doaOnAxis { positive.append("doa_on_axis") }
            else { negative.append("doa_off_axis") }
        } else {
            // Mac mic or no DoA data — don't penalise. The gate
            // simply isn't evaluated; engagement must come from
            // face / verb prefix instead.
            doaOnAxis = false
        }

        // 5c. Engagement signals (need at least one positive).
        let faceVisible: Bool
        if let age = signals.faceVisibleAgeS, age <= config.faceEngageWindowS {
            faceVisible = true
            positive.append("face")
        } else {
            faceVisible = false
        }

        let doaCorroborates =
            (signals.micSource == "robot")
            && (signals.doaIsSpeech == true)
            && doaOnAxis
        if doaCorroborates { positive.append("doa_is_speech") }

        let firstToken = normalised.split(separator: " ").first.map(String.init) ?? ""
        let verbPrefixed = !firstToken.isEmpty
            && config.verbPrefixes.contains(firstToken)
        if verbPrefixed { positive.append("verb_prefix") }

        let engaged = faceVisible || doaCorroborates || verbPrefixed
        if !engaged { negative.append("no_engagement") }

        // 6. Strict decision: ALL gates must pass for a non-wake
        //    transcript to dispatch. Mac mic (no DoA) is allowed
        //    because we don't have that signal — but the other
        //    gates must still hold.
        let doaOk = (signals.micSource == "robot") ? doaOnAxis : true
        let accept = loudEnough && doaOk && engaged

        let score = AddressFilter.score(
            loudEnough: loudEnough,
            doaOk: doaOk,
            engaged: engaged,
            hasDoA: signals.doaRad != nil
        )

        if accept {
            return .dispatch(score: score, reasons: positive, engaged: engaged)
        }
        return .drop(score: score, reasons: negative.isEmpty ? ["uncategorised"] : negative)
    }

    // MARK: - Helpers

    /// Lower-case, strip punctuation, collapse whitespace. Used for
    /// junk-phrase comparison and verb-prefix detection.
    public static func normalise(_ text: String) -> String {
        var t = text.lowercased()
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip terminal punctuation only; keep internal apostrophes
        // / hyphens so words like "don't" still match a "do" prefix
        // if the verb list ever grows.
        var stripped = ""
        for char in t where !".,!?".contains(char) {
            stripped.append(char)
        }
        // Collapse whitespace runs.
        let parts = stripped.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    /// Shortest signed angular difference between two angles in
    /// radians, accounting for wrap-around. Returns value in
    /// `(-π, π]`.
    public static func shortestAngle(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d <= -.pi { d += 2 * .pi }
        return d
    }

    private static func score(
        loudEnough: Bool,
        doaOk: Bool,
        engaged: Bool,
        hasDoA: Bool
    ) -> Double {
        // Composite [0,1] for telemetry. Loudness is the heaviest
        // weight since it's the most discriminating in practice;
        // engagement and DoA are secondary corroborators.
        var total: Double = 0
        if loudEnough { total += 0.45 }
        if engaged    { total += 0.35 }
        if doaOk      { total += hasDoA ? 0.20 : 0.10 }
        return min(1.0, total)
    }
}

// MARK: - Convenience for snapshotted signals

extension AddressFilter.Signals {
    /// Per-call optional DoA centre override, used by tests that
    /// need to set the user's expected centre without poking the
    /// actor's config. Production code reads the centre from the
    /// `Config` via `decide(_:)`.
    var userDoaCenterRad: Double? { nil }
}
