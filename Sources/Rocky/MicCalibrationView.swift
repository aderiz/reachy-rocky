import SwiftUI
import RobotLink
import RockyKit  // RPYPose

/// Guided microphone calibration. Three-phase capture plus an optional
/// verify pass. Each phase has a distinct noise / signal model, so the
/// computed threshold accounts for the room AND the robot's own motor +
/// fan + servo whine — not just one of them. The flow:
///
///   1. **Room** (8 s, robot asleep). Captures HVAC, fan, desktop hum.
///   2. **Robot** (6 s, just woken). Captures motor / servo / fan noise
///      that's only present while the robot is operational.
///   3. **Voice** (12 s, robot still awake). Captures the user speaking
///      naturally with pauses; a coarse RMS-VAD throws out the pauses
///      so they don't drag down `speech_p25`.
///   4. **Verify** (8 s, optional). Threshold drawn as a line on a live
///      VU; the user speaks and watches segments cross. Apply / Re-run.
///
/// Failure modes:
/// - Robot offline → skip phase 2 silently.
/// - Spoke during silence (room or robot) → detect, prompt re-run.
/// - Stayed silent during voice → fall back with a clear message.
///
/// Sampling is at 30 Hz directly from `services.mic.lastRMS` /
/// `services.robotMic.lastRMS` — bypassing the 10 Hz VU mirror so
/// percentile estimates over a phase are stable. The mic must be hot
/// to flow; the sheet auto-enables Listen on entry and restores the
/// prior state on dismiss.
struct MicCalibrationView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    /// Mirrors the user's mic-on state at sheet entry so we restore
    /// it on dismiss whether they completed, cancelled, or hit an
    /// error.
    @State private var micWasEnabled: Bool = false

    /// Whether the robot was awake at sheet entry. Restored after the
    /// flow so calibration is non-disruptive — the user finds the
    /// robot in the same state they left it.
    @State private var robotWasAwake: Bool = false

    @State private var phase: Phase = .intro
    @State private var elapsed: Double = 0
    @State private var roomSamples: [Float] = []
    @State private var robotSamples: [Float] = []
    @State private var voiceSamples: [Float] = []
    /// Direct-address samples — captured while the user speaks to Rocky
    /// from their usual seating position. Used to derive the
    /// `AddressFilter`'s loudness floor / ratio (and the DoA centre /
    /// tolerance, when the robot mic is the active source). Separate
    /// from `voiceSamples` because the voice phase asks the user to
    /// "talk naturally" (any direction); this one asks them to
    /// directly address Rocky.
    @State private var addressSamples: [Float] = []
    @State private var addressDoASamples: [Double] = []
    @State private var verifySamples: [Float] = []
    @State private var verifyTriggers: Int = 0
    @State private var verifyAboveLastTick: Bool = false
    @State private var recommendedThreshold: Float? = nil
    /// Outputs of the new address phase. Populated by
    /// `computeAddressCalibration()` after the address phase finishes.
    @State private var recommendedAddressRMSFloor: Double? = nil
    @State private var recommendedAddressLoudnessRatio: Double? = nil
    @State private var recommendedAddressDoACenter: Double? = nil
    @State private var recommendedAddressDoATolerance: Double? = nil
    @State private var failureReason: String? = nil
    @State private var phaseTask: Task<Void, Never>? = nil

    /// Per-phase durations. Tuned in conversation with the user — the
    /// previous 2 + 3 = 5 s flow felt rushed and didn't separate room
    /// from robot. Total active time is ~34 s with the address phase
    /// added (+ 8 s if the user runs verify), plus wake/sleep
    /// transitions when a robot is connected.
    private let roomSeconds: Double = 8.0
    private let robotSeconds: Double = 6.0
    private let voiceSeconds: Double = 12.0
    private let addressSeconds: Double = 8.0
    private let verifySeconds: Double = 8.0

    /// Sampling cadence. 30 Hz over a 30 ms VAD frame gives roughly one
    /// sample per frame, which is the right granularity for a stable
    /// p99 over 8 s (~240 samples) and a p25 over 12 s (~360 samples).
    /// Higher rates oversample with no statistical gain because the
    /// underlying RMS only updates per-frame.
    private let sampleHz: Double = 30.0

    enum Phase: Equatable {
        case intro
        case preRoomSleeping     // sending goToSleep, waiting for completion
        case room
        case waking              // wakeUp in flight
        case robot               // head + body motion + capture
        case voicePrompt         // waiting for user to press Start
        case voice
        case addressPrompt       // waiting for user to press Start
        case address             // direct-address capture for AddressFilter
        case computing
        case results
        case verify
        case applied
        case failed
    }

    /// Bumped by the footer's "Start speaking" button. The async
    /// orchestration loop polls this counter so it can yield back to
    /// SwiftUI while waiting — simpler than continuation plumbing
    /// across @State + actors.
    @State private var userStartTicks: Int = 0

    var body: some View {
        VStack(spacing: 18) {
            header
            phaseStepper
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 520, height: 520)
        .onAppear { primeAndStart() }
        .onDisappear { teardown() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Image(systemName: "mic.and.signal.meter.fill")
                .font(.title)
                .foregroundStyle(.tint)
            Text("Calibrate microphone")
                .font(.title3.weight(.semibold))
            Text("About 30 seconds. Rocky learns your voice, your room, and his own motor noise.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Phase stepper

    /// Three-dot stepper showing where we are in the capture pipeline.
    /// Once we hit `.computing` or beyond, all three are filled. The
    /// `.verify` and `.applied` states sit beyond the stepper.
    private var phaseStepper: some View {
        HStack(spacing: 10) {
            stepLabel(index: 1, name: "Room", active: phase == .room,
                      done: stepDoneAt(1))
            connector(filled: stepDoneAt(1))
            stepLabel(index: 2, name: "Rocky", active: phase == .robot,
                      done: stepDoneAt(2))
            connector(filled: stepDoneAt(2))
            stepLabel(index: 3, name: "Voice", active: phase == .voice,
                      done: stepDoneAt(3))
            connector(filled: stepDoneAt(3))
            stepLabel(index: 4, name: "Address", active: phase == .address,
                      done: stepDoneAt(4))
        }
        .font(.caption)
    }

    private func stepDoneAt(_ index: Int) -> Bool {
        switch (index, phase) {
        case (1, .robot), (1, .waking),
             (1, .voicePrompt), (1, .voice),
             (1, .addressPrompt), (1, .address),
             (1, .computing), (1, .results),
             (1, .verify), (1, .applied):
            return true
        case (2, .voicePrompt), (2, .voice),
             (2, .addressPrompt), (2, .address),
             (2, .computing), (2, .results),
             (2, .verify), (2, .applied):
            return true
        case (3, .addressPrompt), (3, .address),
             (3, .computing), (3, .results),
             (3, .verify), (3, .applied):
            return true
        case (4, .computing), (4, .results),
             (4, .verify), (4, .applied):
            return true
        default:
            return false
        }
    }

    private func stepLabel(index: Int, name: String, active: Bool, done: Bool) -> some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(done ? AnyShapeStyle(.tint)
                          : active ? AnyShapeStyle(.tint.opacity(0.3))
                          : AnyShapeStyle(.gray.opacity(0.25)))
                    .frame(width: 18, height: 18)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(active ? Color.primary : .secondary)
                }
            }
            Text(name)
                .foregroundStyle(active || done ? Color.primary : .secondary)
        }
    }

    private func connector(filled: Bool) -> some View {
        Rectangle()
            .fill(filled ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(.gray.opacity(0.25)))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Phase content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .intro:
            phaseInstruction(
                title: "About to start",
                subtitle: "Get comfortable. Don't speak yet."
            )
        case .preRoomSleeping:
            phaseInstruction(
                title: "Settling Rocky",
                subtitle: "Sending Rocky to sleep so we can hear the room cleanly. About three seconds."
            )
        case .room:
            phaseRecording(
                title: "Listening to your room",
                subtitle: "Sit quietly. We're sampling HVAC, fan, computer hum.",
                duration: roomSeconds
            )
        case .waking:
            phaseInstruction(
                title: "Waking Rocky",
                subtitle: "Rocky is moving to neutral. Hold on a couple of seconds."
            )
        case .robot:
            phaseRecording(
                title: "Listening to Rocky",
                subtitle: "Don't speak. We're capturing motor and fan noise.",
                duration: robotSeconds
            )
        case .voicePrompt:
            phaseInstruction(
                title: "Ready to speak?",
                subtitle: "Press Start, then talk for about ten seconds. Try a few short sentences with natural pauses — the weather, what's on tomorrow, anything."
            )
        case .voice:
            phaseRecording(
                title: "Now speak normally",
                subtitle: "Talk for about ten seconds. Try a few short sentences with natural pauses. The white line on the bar marks the noise floor: aim for your voice to cross it on every word.",
                duration: voiceSeconds,
                showCutoff: true
            )
        case .addressPrompt:
            phaseInstruction(
                title: "Ready to address Rocky?",
                subtitle: "Press Start when you're seated where you normally sit, then read these to Rocky: \"Rocky, what time is it?\"  \"Rocky, what's the weather?\"  \"Rocky, set a timer for ten minutes.\""
            )
        case .address:
            phaseRecording(
                title: "Address Rocky from your usual spot",
                subtitle: "Talk directly TO Rocky — face him. This teaches him what 'addressed-to-me' sounds and looks like.",
                duration: addressSeconds,
                showCutoff: true
            )
        case .computing:
            phaseInstruction(
                title: "Computing threshold",
                subtitle: "Crunching room + Rocky + voice."
            )
        case .results:
            resultsView
        case .verify:
            verifyView
        case .applied:
            phaseInstruction(
                title: "Calibration applied",
                subtitle: "You can revert from Settings → Voice if it doesn't feel right."
            )
        case .failed:
            failureView
        }
    }

    private func phaseInstruction(title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func phaseRecording(
        title: String, subtitle: String, duration: Double,
        showCutoff: Bool = false
    ) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            ProgressView(value: min(elapsed / duration, 1.0))
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
            vuBar(showCutoff: showCutoff)
                .frame(maxWidth: 320, maxHeight: 14)
            Text(String(format: "Live RMS  %.4f", services.lastMicRMS))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// Full-scale of the VU bar in RMS. Normal indoor conversational
    /// speech sits around 0.04–0.10 RMS at close range; loud speech
    /// can reach 0.15+. The previous full-scale of 0.05 made the bar
    /// peg red on *normal* voice, contradicting the calibration logic
    /// (which compares RMS against a `noise_ceiling × 1.3` cutoff
    /// that could itself land above 0.05). 0.20 reserves the red
    /// zone for genuinely loud audio.
    private static let vuFullScaleRMS: Double = 0.20

    private var liveVUBar: some View {
        return vuBar(showCutoff: false)
            .frame(height: 14)
    }

    /// VU bar shared by both the live recording phases. When
    /// `showCutoff` is true (voice phase), overlay a vertical marker
    /// at `noiseCeiling × speechFloorMultiplier` so the user can see
    /// the threshold their voice needs to cross — the previous UI
    /// only complained "speak louder" after the fact with no live
    /// indicator of what "louder" meant.
    private func vuBar(showCutoff: Bool) -> some View {
        let live = Double(services.lastMicRMS)
        let normalised = min(live / Self.vuFullScaleRMS, 1.0)

        // Cutoff at noise_ceiling × multiplier (matches the cutoff
        // used by `speechOnlyVoiceSamples` and `computeThreshold`).
        let noiseCeiling = max(percentile(roomSamples, 0.99),
                                percentile(robotSamples, 0.99))
        let cutoff = Double(max(noiseCeiling * Float(Self.speechFloorMultiplier),
                                 0.003))
        let cutoffNorm = min(cutoff / Self.vuFullScaleRMS, 1.0)
        let aboveCutoff = showCutoff && live >= cutoff

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.18))
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        colors: [.green, .yellow, .red],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: geo.size.width * normalised)

                if showCutoff && cutoff > 0 {
                    // Vertical line marking where the user's RMS
                    // needs to land to count as "voice". The line
                    // tints green once they cross it so they get
                    // immediate confirmation each time a syllable
                    // lands.
                    Rectangle()
                        .fill(aboveCutoff ? Color.green : Color.white.opacity(0.85))
                        .frame(width: 2)
                        .offset(x: geo.size.width * cutoffNorm - 1)
                        .shadow(color: .black.opacity(0.4),
                                radius: 1, x: 0, y: 0)
                }
            }
        }
    }

    /// Voice-frame detection multiplier applied to the measured
    /// noise ceiling. 1.3 (was 1.5) — less aggressive, so normal-
    /// volume speech in a moderately noisy room still counts as
    /// voice. The room-noise capture's p99 already excludes the
    /// loudest 1% of frames, so a 1.3× headroom on top of that is
    /// enough margin to discriminate.
    private static let speechFloorMultiplier: Double = 1.3

    // MARK: - Results

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Calibration ready")
                .font(.headline)
            if let t = recommendedThreshold {
                statRow("Recommended threshold", value: String(format: "%.4f", t),
                        emphasised: true)
                statRow("Room noise (p99)",
                        value: String(format: "%.4f", percentile(roomSamples, 0.99)))
                if !robotSamples.isEmpty {
                    statRow("Rocky noise (p99)",
                            value: String(format: "%.4f", percentile(robotSamples, 0.99)))
                } else {
                    statRow("Rocky noise", value: "skipped (offline)")
                }
                let speechOnly = speechOnlyVoiceSamples()
                statRow("Your voice (p25)",
                        value: speechOnly.isEmpty
                            ? "—"
                            : String(format: "%.4f", percentile(speechOnly, 0.25)))
                Divider().padding(.vertical, 4)
                Text("Test it before applying — speak in the next phase and watch your sentences cross the threshold line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statRow(_ label: String, value: String, emphasised: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(emphasised
                    ? .body.monospacedDigit().weight(.semibold)
                    : .caption.monospacedDigit())
                .foregroundStyle(emphasised ? Color.primary : .secondary)
        }
    }

    // MARK: - Verify

    private var verifyView: some View {
        VStack(spacing: 12) {
            Text("Test the threshold")
                .font(.headline)
            Text("Speak whenever you like. Sentences that cross the line count as triggered.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView(value: min(elapsed / verifySeconds, 1.0))
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
            verifyVUBarWithLine
                .frame(maxWidth: 320)
            HStack(spacing: 16) {
                statBadge(title: "Detected",
                          value: "\(verifyTriggers) segments",
                          tint: verifyTriggers > 0 ? .green : .secondary)
                statBadge(title: "Threshold",
                          value: String(format: "%.4f",
                                        recommendedThreshold ?? 0))
            }
            Text(String(format: "Live RMS  %.4f", services.lastMicRMS))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var verifyVUBarWithLine: some View {
        // Same full-scale as the live bar — voice "red" should mean
        // the same thing on both screens.
        let live = Double(services.lastMicRMS)
        let normalised = min(live / Self.vuFullScaleRMS, 1.0)
        let threshold = Double(recommendedThreshold ?? 0)
        let thresholdNorm = min(threshold / Self.vuFullScaleRMS, 1.0)
        let above = live >= threshold
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.18))
                RoundedRectangle(cornerRadius: 4)
                    .fill(above ? Color.green.opacity(0.85)
                          : Color.gray.opacity(0.45))
                    .frame(width: geo.size.width * normalised)
                Rectangle()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 2)
                    .offset(x: geo.size.width * thresholdNorm)
            }
        }
        .frame(height: 18)
    }

    private func statBadge(title: String, value: String,
                           tint: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Failure

    private var failureView: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Calibration didn't land")
                .font(.headline)
            Text(failureReason ?? "Couldn't compute a sensible threshold from the captured audio.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text("Threshold was not changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            switch phase {
            case .intro, .preRoomSleeping, .room, .waking, .robot, .voice, .address, .computing:
                Button("Recording…") {}.disabled(true)
            case .voicePrompt, .addressPrompt:
                Button("Start") { userStartTicks += 1 }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .results:
                Button("Apply without verify") { applyAndDismiss() }
                Button("Test it") { Task { await runVerify() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .verify:
                Button("Stop") { phaseTask?.cancel() }
                    .disabled(true)  // verify is short; let it finish
            case .applied:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .failed:
                Button("Re-run") { Task { await runFullFlow() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Lifecycle

    private func primeAndStart() {
        micWasEnabled = services.micEnabled
        if !services.micEnabled {
            // Toggle Listen on so the VU pump starts producing
            // RMS values. AppServices' toggle is async; the brief
            // delay before phase 1 actually starts gives the audio
            // chain time to spin up.
            Task { await services.toggleMic() }
        }
        // Snapshot robot wake-state. We wake/sleep around the flow,
        // so the post-flow restore runs whichever transition was
        // needed. Anything that isn't `.sleeping` counts as "was
        // awake" — `.waking` mid-flight is treated as awake so a
        // calibration started right after wake doesn't accidentally
        // restore-to-asleep.
        switch services.rockyState {
        case .sleeping:
            robotWasAwake = false
        case .waking, .idle, .tracking, .listening,
             .thinking, .speaking, .error:
            robotWasAwake = true
        }

        phaseTask = Task { await runFullFlow() }
    }

    private func teardown() {
        phaseTask?.cancel()
        phaseTask = nil
        // Best-effort restore: if the user had Listen off, turn it
        // off again. If the user had Rocky asleep, send him back to
        // sleep. Both are fire-and-forget — failures are non-fatal.
        if !micWasEnabled, services.micEnabled {
            Task { await services.toggleMic() }
        }
        if !robotWasAwake,
           services.daemonReachability == .online {
            // Use the Mac-side sleepRobot() so the streamer is
            // suppressed during the slump — same reason as the
            // wake path in runFullFlow().
            Task { await services.sleepRobot() }
        }
    }

    // MARK: - Phase orchestration

    private func runFullFlow() async {
        // Reset state so a re-run starts clean.
        await MainActor.run {
            roomSamples = []
            robotSamples = []
            voiceSamples = []
            addressSamples = []
            addressDoASamples = []
            verifySamples = []
            verifyTriggers = 0
            recommendedThreshold = nil
            recommendedAddressRMSFloor = nil
            recommendedAddressLoudnessRatio = nil
            recommendedAddressDoACenter = nil
            recommendedAddressDoATolerance = nil
            failureReason = nil
            phase = .intro
        }

        // Brief pause so the user reads the intro. If micWasEnabled
        // was false at entry, this also lets `toggleMic()` settle.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if Task.isCancelled { return }

        // Phase 1: Room. If Rocky's awake, send him to sleep first
        // so motor noise doesn't pollute the room sample. Use the
        // Mac-side `sleepRobot()` (not the raw `robotLink.goToSleep`)
        // so the 50 Hz face-tracker streamer is suppressed for the
        // sleep duration via `transitioningUntil` — without that
        // gate, the streamer fights the daemon's slump animation.
        if services.daemonReachability == .online,
           robotWasAwake {
            await MainActor.run { phase = .preRoomSleeping }
            await services.sleepRobot()
        }
        if Task.isCancelled { return }

        await MainActor.run { phase = .room }
        roomSamples = await capturePhase(seconds: roomSeconds)
        if Task.isCancelled { return }

        // Sanity: if the room phase looks like the user was talking,
        // bail with a clear message. Heuristic: any sample above 0.02
        // is "definitely speech" volume; if more than ~20% of room
        // samples are above that, the user spoke during the silent
        // phase.
        let roomLoud = roomSamples.filter { $0 > 0.02 }.count
        if !roomSamples.isEmpty,
           Double(roomLoud) / Double(roomSamples.count) > 0.2 {
            await failOut(reason: "We picked up speech during the room phase. Stay quiet for those eight seconds and try again.")
            return
        }

        // Phase 2: Robot. Skip silently if the daemon is offline or
        // the wake fails.
        if services.daemonReachability == .online {
            await MainActor.run { phase = .waking }
            // Use the Mac-side wakeRobot() (not raw robotLink.wakeUp())
            // so the face-tracker streamer is suppressed for the wake
            // duration via `transitioningUntil`. Otherwise the
            // streamer's 50 Hz set_target stream overrides the
            // daemon's minjerk goto-neutral immediately, and Rocky
            // ends up pointed at whatever face is in view rather than
            // his home position.
            await services.wakeRobot()
            if Task.isCancelled { return }

            // Brief settle so the wake-up move's tail doesn't show
            // up in the robot sample.
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }

            await MainActor.run { phase = .robot }
            // Take exclusive control of the motors for the motor
            // phase so nothing else can steal attention. Three
            // layers of suppression:
            //   1. transitioningUntil — gates the AppServices
            //      streamer-control watcher loop.
            //   2. targetStreamer.setPrimaryMoveActive(true) —
            //      direct streamer suppression with no watcher lag.
            //   3. setFaceTrackingEnabled(false) — stops the
            //      MacFaceTracker from generating new targets at all
            //      (so even if the streamer un-suppresses, there's
            //      nothing to stream).
            // All three are restored at the end of the phase.
            let wasFaceTracking = services.faceTrackingEnabled
            await MainActor.run {
                services.transitioningUntil =
                    Date().addingTimeInterval(robotSeconds + 1.5)
            }
            await services.targetStreamer.setPrimaryMoveActive(true)
            await services.setFaceTrackingEnabled(false)

            // Smooth 50 Hz parametric sweep — same cadence the face
            // tracker uses, so Rocky reads as "tracking something"
            // rather than executing a series of discrete poses with
            // pauses between them. Continuous motion is what makes
            // the motors run continuously, which is what we need to
            // measure their realistic operational noise floor.
            async let motion: Void = streamLissajousMotion(during: robotSeconds)
            robotSamples = await capturePhase(seconds: robotSeconds)
            _ = await motion

            // Return to neutral and restore the suppressed signals.
            // Goto blocks until the move completes so we don't hand
            // control back to face tracking mid-arc.
            try? await services.robotLink.goto(
                headPose: RPYPose(roll: 0, pitch: 0, yaw: 0),
                antennas: nil, bodyYaw: 0, durationS: 1.0
            )
            await services.targetStreamer.setPrimaryMoveActive(false)
            await services.setFaceTrackingEnabled(wasFaceTracking)
            await MainActor.run { services.transitioningUntil = nil }
            if Task.isCancelled { return }

            // No "user spoke during Rocky" sanity check here. The
            // motion sequence drives the motors deliberately, and
            // peak motor RMS routinely exceeds 0.02 — which is
            // precisely what we want to MEASURE, not a failure
            // condition.
        }

        // Phase 3: Voice — user-gated. Show the prompt and wait for
        // the Start button before recording. Speech capture should
        // never fire without the user actively initiating it.
        await MainActor.run { phase = .voicePrompt }
        await waitForUserStart()
        if Task.isCancelled { return }
        await MainActor.run { phase = .voice }
        voiceSamples = await capturePhase(seconds: voiceSeconds)
        if Task.isCancelled { return }

        // Phase 4: Address — also user-gated. Same prompt pattern as
        // phase 3. Captures direct-address loudness and (on robot
        // mic) the user's typical DoA from where they sit.
        await MainActor.run { phase = .addressPrompt }
        await waitForUserStart()
        if Task.isCancelled { return }
        await MainActor.run { phase = .address }
        let (addressR, addressD) = await captureAddressPhase(seconds: addressSeconds)
        addressSamples = addressR
        addressDoASamples = addressD
        if Task.isCancelled { return }

        // Compute.
        await MainActor.run { phase = .computing }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let result = computeThreshold()
        if Task.isCancelled { return }

        // Address-filter values: best-effort, never fails the flow.
        // Stored to @State, then committed in applyThresholdToServices.
        let addressResult = computeAddressCalibration()
        await MainActor.run {
            recommendedAddressRMSFloor = addressResult.rmsFloor
            recommendedAddressLoudnessRatio = addressResult.loudnessRatio
            recommendedAddressDoACenter = addressResult.doaCenter
            recommendedAddressDoATolerance = addressResult.doaTolerance
        }
        // Surface the four computed values to the Logs view so the
        // user can see exactly what calibration produced. This is
        // the diagnostic surface that makes "calibration didn't
        // land" debuggable instead of mysterious.
        await services.logBus.publish(.sidecarLog(
            sidecar: "calibration", level: .info,
            message: "calibration computed",
            fields: [
                "room_p99": String(format: "%.4f", percentile(roomSamples, 0.99)),
                "robot_p99": String(format: "%.4f", percentile(robotSamples, 0.99)),
                "address_p25": String(format: "%.4f",
                    addressSamples.isEmpty ? 0 : percentile(addressSamples, 0.25)),
                "address_p50": String(format: "%.4f",
                    addressSamples.isEmpty ? 0 : percentile(addressSamples, 0.50)),
                "address_rms_floor": String(format: "%.4f", addressResult.rmsFloor),
                "address_loud_ratio": String(format: "%.2f", addressResult.loudnessRatio),
                "address_doa_centre_rad": String(format: "%.2f", addressResult.doaCenter),
                "address_doa_tolerance_rad": String(format: "%.2f", addressResult.doaTolerance),
                "address_doa_sample_count": "\(addressDoASamples.count)"
            ]
        ))

        switch result {
        case .success(let value):
            await MainActor.run {
                recommendedThreshold = value
                phase = .results
            }
        case .failure(let reason):
            await failOut(reason: reason)
        }
    }

    /// Block the orchestration loop until the user presses the
    /// "Start" button in the footer (which bumps `userStartTicks`).
    /// Polled at 10 Hz — well below human reaction latency and cheap
    /// enough to not show up in instruments. Cancellation-aware so
    /// dismissing the sheet mid-wait exits cleanly.
    private func waitForUserStart() async {
        let baseline = userStartTicks
        while !Task.isCancelled {
            if userStartTicks > baseline { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Stream a smooth 50 Hz parametric head sweep for `seconds` —
    /// same cadence and pose-stream shape as the face tracker, so
    /// Rocky reads as "tracking a moving face" rather than executing
    /// a chain of discrete poses with pauses between. Continuous
    /// motion keeps the motors running continuously, which is the
    /// noise profile we actually want to measure.
    ///
    /// The path is a Lissajous figure in (yaw, pitch) space with
    /// coprime periods so the trace doesn't trivially repeat in the
    /// 6-second window. Amplitudes are tuned to look like tracking,
    /// not dancing — peak yaw ~16°, peak pitch ~6°.
    ///
    /// The caller is responsible for gating any competing target
    /// source (face tracker, streamer) before invoking this and
    /// restoring them afterwards.
    private func streamLissajousMotion(during seconds: Double) async {
        // 50 Hz tick. Match the face tracker / streamer cadence so
        // the daemon sees the same target-update pattern it sees
        // during normal operation.
        let tickIntervalNs: UInt64 = 20_000_000
        let totalTicks = Int(seconds * 50)
        // Slow sinusoidal sweeps with coprime periods so the path
        // doesn't repeat in the capture window. Periods chosen so
        // the bot's never *quite* in the same place twice — keeps
        // the motors continuously commanded to a fresh target.
        let yawAmp: Double = 0.28      // ~16°
        let pitchAmp: Double = 0.10    // ~6°
        let yawPeriod: Double = 3.7
        let pitchPeriod: Double = 2.3
        for tick in 0..<totalTicks {
            if Task.isCancelled { return }
            let t = Double(tick) / 50.0
            let yaw = yawAmp * sin(2 * .pi * t / yawPeriod)
            let pitch = pitchAmp * sin(2 * .pi * t / pitchPeriod)
            let pose = RPYPose(roll: 0, pitch: pitch, yaw: yaw)
            // Post directly to the daemon's set_target endpoint,
            // bypassing the Mac-side TargetStreamer (which we've
            // suppressed). Each call is fire-and-forget; daemon
            // overwrites the active target on receipt and the
            // motor control loop interpolates smoothly.
            try? await services.robotLink.setTarget(
                MotionTarget(headPose: pose, antennas: nil, bodyYaw: 0)
            )
            try? await Task.sleep(nanoseconds: tickIntervalNs)
        }
    }

    /// Like `capturePhase` but also samples the robot mic's live DoA
    /// at 10 Hz alongside the RMS samples. DoA capture is a no-op when
    /// the active mic source is Mac (no array → no DoA data).
    private func captureAddressPhase(seconds: Double) async -> (rms: [Float], doa: [Double]) {
        var rmsSamples: [Float] = []
        var doaSamples: [Double] = []
        let intervalNs = UInt64(1_000_000_000 / sampleHz)
        let totalSamples = Int(seconds * sampleHz)
        // DoA samples land every 3rd RMS tick to keep the rate near
        // 10 Hz without coordinating two timers.
        let doaStride = max(1, Int(sampleHz / 10))
        let started = Date()
        await MainActor.run { self.elapsed = 0 }
        for i in 0..<totalSamples {
            if Task.isCancelled { break }
            let rms = await readRMS()
            rmsSamples.append(rms)
            if services.settings.micSource == "robot", i % doaStride == 0 {
                if let doa = await services.robotMic.lastDoaRad,
                   await services.robotMic.lastDoaIsSpeech == true {
                    doaSamples.append(doa)
                }
            }
            await MainActor.run {
                self.elapsed = Date().timeIntervalSince(started)
            }
            if i < totalSamples - 1 {
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
        return (rmsSamples, doaSamples)
    }

    /// Derive the AddressFilter calibration values from the captured
    /// address-phase samples + percentiles. Returns sensible defaults
    /// for any field where evidence is insufficient.
    ///
    /// Important: the noise ceiling here uses **room only**, not
    /// motors-under-load. The AddressFilter runs at conversational
    /// dispatch time — i.e., when Rocky is awake but stationary and
    /// the motors are idle. Idle motor noise is near-ambient, so
    /// room P99 is the relevant background. Including the
    /// motion-loaded robot phase here would inflate the ceiling to
    /// motor-peak levels, making `addressLoudnessRatio` unattainable
    /// for normal speech.
    private func computeAddressCalibration() -> (
        rmsFloor: Double, loudnessRatio: Double,
        doaCenter: Double, doaTolerance: Double
    ) {
        let roomCeiling = Double(percentile(roomSamples, 0.99))
        let addressP50 = addressSamples.isEmpty ? 0
            : Double(percentile(addressSamples, 0.50))
        let addressP25 = addressSamples.isEmpty ? 0
            : Double(percentile(addressSamples, 0.25))
        // Floor: the user's quieter half of address speech needs to
        // pass, so cap at ~80% of P25. Hard minimum 0.005 catches
        // quantisation / dead air.
        let floor: Double
        if addressP25 > 0 {
            floor = max(0.005, min(addressP25 * 0.8, 0.04))
        } else {
            floor = 0.012  // default
        }
        // Ratio: room is typically 0.001-0.005 RMS. Address speech is
        // 0.04-0.12. Ratio of 8-40×. Cap at 6× so the gate is
        // achievable for slightly-quieter follow-ups. Floor at 2×
        // so we always have *some* discrimination over background.
        let ratio: Double
        if roomCeiling > 1e-6 && addressP50 > roomCeiling {
            ratio = max(2.0, min(addressP50 / roomCeiling * 0.5, 6.0))
        } else {
            ratio = 4.0  // default
        }

        // DoA: circular mean + 2× circular MAD from the captured
        // samples. Falls back to "facing the bot" (0 rad) with a wide
        // default tolerance when there's no usable data.
        let (centre, tolerance) = circularMeanAndMAD(addressDoASamples)
        return (
            rmsFloor: floor,
            loudnessRatio: ratio,
            doaCenter: centre,
            doaTolerance: tolerance
        )
    }

    /// Circular mean + 2× MAD of an array of angles in radians.
    /// Returns (0, 0.45) when the array is empty / too small to be
    /// meaningful — those are the same defaults `SettingsStore` ships
    /// with so the AddressFilter remains conservative when DoA is
    /// missing.
    private func circularMeanAndMAD(_ angles: [Double]) -> (centre: Double, tolerance: Double) {
        guard angles.count >= 5 else { return (0, 0.45) }
        let sumX = angles.reduce(0.0) { $0 + cos($1) }
        let sumY = angles.reduce(0.0) { $0 + sin($1) }
        let mean = atan2(sumY / Double(angles.count), sumX / Double(angles.count))
        let deltas = angles.map { angle -> Double in
            var d = (angle - mean).truncatingRemainder(dividingBy: 2 * .pi)
            if d > .pi { d -= 2 * .pi }
            if d <= -.pi { d += 2 * .pi }
            return abs(d)
        }
        // MAD = median absolute deviation; robust to outliers.
        let sorted = deltas.sorted()
        let median = sorted[sorted.count / 2]
        let tol = min(max(median * 2.0, 0.25), 0.9)
        return (mean, tol)
    }

    private func runVerify() async {
        await MainActor.run {
            verifySamples = []
            verifyTriggers = 0
            verifyAboveLastTick = false
            phase = .verify
        }
        guard let threshold = recommendedThreshold else { return }
        let intervalNs = UInt64(1_000_000_000 / sampleHz)
        let totalSamples = Int(verifySeconds * sampleHz)
        let started = Date()
        for i in 0..<totalSamples {
            if Task.isCancelled { break }
            let rms = await readRMS()
            await MainActor.run {
                self.elapsed = Date().timeIntervalSince(started)
                self.verifySamples.append(rms)
                // Edge-trigger on rising crossings so a single
                // sustained "Hello" doesn't count as ten triggers.
                let above = rms >= threshold
                if above, !self.verifyAboveLastTick {
                    self.verifyTriggers += 1
                }
                self.verifyAboveLastTick = above
            }
            if i < totalSamples - 1 {
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
        // Verify finished — don't auto-apply; let the user decide.
        // We surface Apply via the footer's Apply-without-verify
        // button after results, and after verify the same Apply
        // path remains available as the primary action.
        await MainActor.run { phase = .applied }
        applyThresholdToServices()
    }

    private func failOut(reason: String) async {
        await MainActor.run {
            failureReason = reason
            phase = .failed
        }
    }

    // MARK: - Capture

    /// Polls `mic.lastRMS` / `robotMic.lastRMS` directly at `sampleHz`
    /// for the duration. Returns every observed sample. Reads the
    /// underlying mic service rather than the 10 Hz `services.lastMicRMS`
    /// VU mirror so we get one fresh value per audio frame instead of
    /// stride-aliased duplicates.
    private func capturePhase(seconds: Double) async -> [Float] {
        var samples: [Float] = []
        let intervalNs = UInt64(1_000_000_000 / sampleHz)
        let totalSamples = Int(seconds * sampleHz)
        let started = Date()
        await MainActor.run { self.elapsed = 0 }
        for i in 0..<totalSamples {
            if Task.isCancelled { break }
            let rms = await readRMS()
            samples.append(rms)
            await MainActor.run {
                self.elapsed = Date().timeIntervalSince(started)
            }
            if i < totalSamples - 1 {
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
        return samples
    }

    /// Read the freshest RMS value from whichever mic the user has
    /// configured. Mac mic is a class-bound `lastRMS` (synchronous
    /// read); robot mic is an actor and needs `await`.
    private func readRMS() async -> Float {
        if services.settings.micSource == "robot" {
            return await services.robotMic.lastRMS
        }
        return services.mic.lastRMS
    }

    // MARK: - Threshold math

    private enum ComputeResult {
        case success(Float)
        case failure(String)
    }

    /// Pull the speech-only RMS samples from `voiceSamples` by running
    /// a coarse RMS-VAD: anything above
    /// `noise_ceiling × speechFloorMultiplier` counts as a voice
    /// frame; the rest is the user pausing between words. Without
    /// this, `speech_p25` is dominated by inter-word silence and the
    /// threshold ends up too low.
    private func speechOnlyVoiceSamples() -> [Float] {
        guard !voiceSamples.isEmpty else { return [] }
        let noiseCeiling = max(percentile(roomSamples, 0.99),
                               percentile(robotSamples, 0.99))
        let cutoff = max(noiseCeiling * Float(Self.speechFloorMultiplier),
                          0.003)
        return voiceSamples.filter { $0 >= cutoff }
    }

    private func computeThreshold() -> ComputeResult {
        guard !roomSamples.isEmpty, !voiceSamples.isEmpty else {
            return .failure("We didn't collect enough samples to set a threshold. Make sure your mic is on and try again.")
        }
        let roomP99 = percentile(roomSamples, 0.99)
        let robotP99 = robotSamples.isEmpty ? 0 : percentile(robotSamples, 0.99)
        let noiseCeiling = max(roomP99, robotP99)

        let speechOnly = speechOnlyVoiceSamples()
        // Need a meaningful chunk of voice frames above noise. Less
        // than 10% means the user's voice didn't stand out from the
        // room noise floor — either they didn't speak, the mic gain
        // is too low, or the room noise we measured was unusually
        // high. Diagnose the most likely cause from the captured
        // amplitudes so the failure message is actually actionable.
        let voiceFraction = Double(speechOnly.count)
            / Double(voiceSamples.count)
        if voiceFraction < 0.10 || speechOnly.count < 10 {
            let voiceP90 = percentile(voiceSamples, 0.90)
            let cutoff = max(noiseCeiling * Float(Self.speechFloorMultiplier),
                              0.003)
            let reason: String
            if voiceP90 < 0.003 {
                reason = "We barely heard anything from your mic at all (loudest frames \(String(format: "%.4f", voiceP90))). Check that the right mic is selected in Settings → Voice, and that it isn't muted at the OS level."
            } else if voiceP90 < cutoff {
                reason = "Your voice came through (peak \(String(format: "%.4f", voiceP90))) but the room is noisy enough (ceiling \(String(format: "%.4f", noiseCeiling))) that the system couldn't separate speech from background. Move somewhere quieter, or speak closer to the mic, and try again."
            } else {
                reason = "We didn't pick up enough sustained voice — maybe long pauses between words. Speak in a few short sentences without big gaps, and try again."
            }
            return .failure(reason)
        }

        let speechP25 = percentile(speechOnly, 0.25)

        // Threshold sits between noise_ceiling × 1.3 (just clear of
        // the loudest noise we measured) and speech_p25 (well below
        // any normal word). Position 0.4 of the way up: closer to
        // noise so quiet / distant speech still triggers.
        let lower = max(noiseCeiling * Float(Self.speechFloorMultiplier),
                         0.003)
        let upper = max(speechP25, lower * 1.001)
        let threshold = lower + (upper - lower) * 0.4
        // Hard clamp: never below 0.003 (catches quantisation noise
        // + dead air) and never above 0.10 (would miss most quiet
        // speech). Cap raised from 0.05 to match the wider voice-
        // amplitude range we now expect from the VU.
        let clamped = min(max(threshold, 0.003), 0.10)
        return .success(clamped)
    }

    /// Linear-interpolated percentile (matches numpy's default).
    /// Returns 0 for an empty array — callers must check non-empty
    /// before reading the result as meaningful.
    private func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let pos = p * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = Int(pos.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = Float(pos - Double(lo))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    // MARK: - Apply

    private func applyAndDismiss() {
        applyThresholdToServices()
        phase = .applied
    }

    private func applyThresholdToServices() {
        guard let t = recommendedThreshold else { return }
        // Stamp previous before changing current — see
        // SettingsStore.applyCalibratedThreshold.
        services.settings.applyCalibratedThreshold(Double(t))
        // Live-apply to the running VAD without waiting for the
        // next applySettings cycle.
        Task { await services.voice.setVADThreshold(t) }

        // Push the address-phase results into AppServices so the
        // AddressFilter starts using them on the very next dispatch.
        // Each value falls back to the prior persisted setting when
        // calibration didn't produce one (e.g. capture failed, Mac
        // mic with no DoA).
        let rmsFloor = recommendedAddressRMSFloor
            ?? services.settings.addressRMSFloor
        let loudnessRatio = recommendedAddressLoudnessRatio
            ?? services.settings.addressLoudnessRatio
        let doaCenter = recommendedAddressDoACenter
            ?? services.settings.addressUserDoaCenterRad
        let doaTolerance = recommendedAddressDoATolerance
            ?? services.settings.addressUserDoaToleranceRad
        Task {
            await services.applyAddressFilterCalibration(
                rmsFloor: rmsFloor,
                loudnessRatio: loudnessRatio,
                userDoaCenterRad: doaCenter,
                userDoaToleranceRad: doaTolerance
            )
        }
    }
}
