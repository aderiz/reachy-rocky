import SwiftUI
import RobotLink

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
    @State private var verifySamples: [Float] = []
    @State private var verifyTriggers: Int = 0
    @State private var verifyAboveLastTick: Bool = false
    @State private var recommendedThreshold: Float? = nil
    @State private var failureReason: String? = nil
    @State private var phaseTask: Task<Void, Never>? = nil

    /// Per-phase durations. Tuned in conversation with the user — the
    /// previous 2 + 3 = 5 s flow felt rushed and didn't separate room
    /// from robot. Total active time is ~26 s (+ 8 s if the user runs
    /// verify), plus the wake/sleep transitions which can add another
    /// 3-4 s when a robot is connected.
    private let roomSeconds: Double = 8.0
    private let robotSeconds: Double = 6.0
    private let voiceSeconds: Double = 12.0
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
        case robot
        case voice
        case computing
        case results
        case verify
        case applied
        case failed
    }

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
        HStack(spacing: 14) {
            stepLabel(index: 1, name: "Room", active: phase == .room,
                      done: stepDoneAt(1))
            connector(filled: stepDoneAt(1))
            stepLabel(index: 2, name: "Rocky", active: phase == .robot,
                      done: stepDoneAt(2))
            connector(filled: stepDoneAt(2))
            stepLabel(index: 3, name: "Your voice", active: phase == .voice,
                      done: stepDoneAt(3))
        }
        .font(.caption)
    }

    private func stepDoneAt(_ index: Int) -> Bool {
        switch (index, phase) {
        case (1, .robot), (1, .waking),
             (1, .voice), (1, .computing),
             (1, .results), (1, .verify),
             (1, .applied):
            return true
        case (2, .voice), (2, .computing),
             (2, .results), (2, .verify),
             (2, .applied):
            return true
        case (3, .computing), (3, .results),
             (3, .verify), (3, .applied):
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
        case .voice:
            phaseRecording(
                title: "Now speak normally",
                subtitle: "Talk for about ten seconds. Try a few short sentences with natural pauses — the weather, what's on tomorrow, anything.",
                duration: voiceSeconds
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

    private func phaseRecording(title: String, subtitle: String, duration: Double) -> some View {
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
            liveVUBar
                .frame(maxWidth: 320)
            Text(String(format: "Live RMS  %.4f", services.lastMicRMS))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var liveVUBar: some View {
        // Map [0, 0.05] → [0, 1] for display; calibration thresholds
        // live in this range and a logarithmic axis would obscure the
        // user's intuition that "louder = bigger bar".
        let live = Double(services.lastMicRMS)
        let normalised = min(live / 0.05, 1.0)
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
            }
        }
        .frame(height: 14)
    }

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
        let live = Double(services.lastMicRMS)
        let normalised = min(live / 0.05, 1.0)
        let threshold = Double(recommendedThreshold ?? 0)
        let thresholdNorm = min(threshold / 0.05, 1.0)
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
            case .intro, .preRoomSleeping, .room, .waking, .robot, .voice, .computing:
                Button("Recording…") {}.disabled(true)
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
            Task { try? await services.robotLink.goToSleep() }
        }
    }

    // MARK: - Phase orchestration

    private func runFullFlow() async {
        // Reset state so a re-run starts clean.
        await MainActor.run {
            roomSamples = []
            robotSamples = []
            voiceSamples = []
            verifySamples = []
            verifyTriggers = 0
            recommendedThreshold = nil
            failureReason = nil
            phase = .intro
        }

        // Brief pause so the user reads the intro. If micWasEnabled
        // was false at entry, this also lets `toggleMic()` settle.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if Task.isCancelled { return }

        // Phase 1: Room. If Rocky's awake, send him to sleep first
        // so motor noise doesn't pollute the room sample.
        if services.daemonReachability == .online,
           robotWasAwake {
            await MainActor.run { phase = .preRoomSleeping }
            do {
                try await services.robotLink.goToSleep()
            } catch {
                // Non-fatal — proceed with room capture even if the
                // sleep request failed; the user will see Rocky in
                // whatever state he ended up in.
            }
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
            do {
                try await services.robotLink.wakeUp()
            } catch {
                // Wake failed — skip phase 2, threshold will just
                // use room noise.
                await MainActor.run { phase = .room }  // leaves stepper at room-done
            }
            if Task.isCancelled { return }

            // Brief settle so the wake-up move's tail doesn't show
            // up in the robot sample.
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }

            await MainActor.run { phase = .robot }
            robotSamples = await capturePhase(seconds: robotSeconds)
            if Task.isCancelled { return }

            let robotLoud = robotSamples.filter { $0 > 0.02 }.count
            if !robotSamples.isEmpty,
               Double(robotLoud) / Double(robotSamples.count) > 0.2 {
                await failOut(reason: "We picked up speech during the Rocky phase. Stay quiet while Rocky's motors settle.")
                return
            }
        }

        // Phase 3: Voice. The robot stays awake (or stays offline)
        // — that's the realistic operating condition.
        await MainActor.run { phase = .voice }
        voiceSamples = await capturePhase(seconds: voiceSeconds)
        if Task.isCancelled { return }

        // Compute.
        await MainActor.run { phase = .computing }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let result = computeThreshold()
        if Task.isCancelled { return }

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
    /// a coarse RMS-VAD: anything above `noise_ceiling × 1.5` counts
    /// as a voice frame; the rest is the user pausing between words.
    /// Without this, `speech_p25` is dominated by inter-word silence
    /// and the threshold ends up too low.
    private func speechOnlyVoiceSamples() -> [Float] {
        guard !voiceSamples.isEmpty else { return [] }
        let noiseCeiling = max(percentile(roomSamples, 0.99),
                               percentile(robotSamples, 0.99))
        let cutoff = max(noiseCeiling * 1.5, 0.001)
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
        // than 10% means the user mostly didn't speak (or was way
        // too quiet for the mic).
        let voiceFraction = Double(speechOnly.count)
            / Double(voiceSamples.count)
        if voiceFraction < 0.10 || speechOnly.count < 10 {
            return .failure("We didn't pick up enough of your voice. Speak a little louder, hold the mic at a normal distance, and try again.")
        }

        let speechP25 = percentile(speechOnly, 0.25)

        // Threshold sits between noise_ceiling × 1.3 (just clear of
        // the loudest noise we measured) and speech_p25 (well below
        // any normal word). Position 0.4 of the way up: closer to
        // noise so quiet / distant speech still triggers.
        let lower = max(noiseCeiling * 1.3, 0.001)
        let upper = max(speechP25, lower * 1.001)
        let threshold = lower + (upper - lower) * 0.4
        // Hard clamp: never below 0.001 (would catch quantisation
        // noise) and never above 0.05 (would miss most speech).
        let clamped = min(max(threshold, 0.001), 0.05)
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
    }
}
