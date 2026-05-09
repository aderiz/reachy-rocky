import SwiftUI

/// Guided microphone calibration. Two-phase capture: a "quiet" phase
/// samples the room's noise floor, then a "speak" phase samples the
/// user's normal speaking RMS. The threshold is set above noise but
/// well below speech so quiet/distant speech still triggers VAD while
/// HVAC, fan, and desktop noise do not.
///
/// The sheet polls `services.lastMicRMS` at 20 Hz — the same VU value
/// the rest of the app already shows. No new audio capture path is
/// added. The mic must be in Listen mode for sampling to succeed; the
/// sheet auto-enables it on entry and restores the previous state on
/// dismiss so calibration doesn't leave the user's setup changed.
struct MicCalibrationView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    /// Mirrors the user's mic-on state at sheet entry, so we can
    /// restore it on dismiss whether they completed or cancelled.
    @State private var micWasEnabled: Bool = false

    @State private var phase: Phase = .intro
    @State private var elapsed: Double = 0
    @State private var noiseSamples: [Float] = []
    @State private var speechSamples: [Float] = []
    @State private var recommendedThreshold: Float? = nil

    /// Quiet phase duration. Two seconds is plenty to capture room
    /// noise (HVAC fan, desk hum) while not boring the user; a
    /// shorter window risks missing intermittent spikes.
    private let quietSeconds: Double = 2.0

    /// Speech phase duration. Three seconds = roughly one short
    /// sentence ("Rocky, what time is it") which is enough to
    /// estimate the 25th-percentile speech RMS reliably.
    private let speechSeconds: Double = 3.0

    enum Phase: Equatable {
        case intro
        case quiet
        case speak
        case done
    }

    var body: some View {
        VStack(spacing: 20) {
            header
            phaseView
            Spacer(minLength: 0)
            footerButtons
        }
        .padding(24)
        .frame(width: 460, height: 380)
        .onAppear { primeMicForCalibration() }
        .onDisappear { restoreMicState() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "mic.and.signal.meter.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Calibrate microphone")
                .font(.title2.weight(.semibold))
        }
    }

    // MARK: - Phase content

    @ViewBuilder
    private var phaseView: some View {
        switch phase {
        case .intro:
            introContent
        case .quiet:
            recordingContent(
                title: "Sampling room noise",
                subtitle: "Don't speak. Rocky is listening to the room.",
                duration: quietSeconds
            )
        case .speak:
            recordingContent(
                title: "Speak normally",
                subtitle: "Try saying \u{201C}Rocky, what time is it?\u{201D}",
                duration: speechSeconds
            )
        case .done:
            doneContent
        }
    }

    private var introContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rocky needs to know how loud your voice and your room are so " +
                 "he triggers on you, not on background noise.")
            Text("This takes about five seconds:")
                .padding(.top, 4)
            Label("Two seconds of silence — Rocky measures the room.",
                  systemImage: "1.circle.fill")
            Label("Three seconds of you speaking normally.",
                  systemImage: "2.circle.fill")
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recordingContent(
        title: String,
        subtitle: String,
        duration: Double
    ) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView(value: min(elapsed / duration, 1.0))
                .progressViewStyle(.linear)
            liveVUBar
            Text(String(format: "Live RMS: %.4f", services.lastMicRMS))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var liveVUBar: some View {
        // Map [0, 0.05] → [0, 1] for display; calibration thresholds
        // live in this range and a logarithmic axis would obscure the
        // user's intuition that "louder = bigger bar".
        let normalised = min(Double(services.lastMicRMS) / 0.05, 1.0)
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
        .frame(height: 12)
    }

    private var doneContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Calibration complete")
                .font(.headline)
            if let t = recommendedThreshold {
                HStack {
                    Text("Threshold")
                    Spacer()
                    Text(String(format: "%.4f", t))
                        .font(.body.monospacedDigit().weight(.medium))
                }
                if !noiseSamples.isEmpty {
                    HStack {
                        Text("Room noise (max)")
                        Spacer()
                        Text(String(format: "%.4f",
                                    noiseSamples.max() ?? 0))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if !speechSamples.isEmpty {
                    let median = percentile(speechSamples, 0.5)
                    HStack {
                        Text("Your voice (median)")
                        Spacer()
                        Text(String(format: "%.4f", median))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.vertical, 4)
                Text("Rocky will trigger on speech louder than this " +
                     "value. Click Apply to save it, or Re-run to try " +
                     "again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Couldn't compute a threshold from the captured " +
                     "audio — was the mic on? Try again.")
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footerButtons: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            switch phase {
            case .intro:
                Button("Start") { Task { await runCalibration() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .quiet, .speak:
                Button("Recording…") {}
                    .disabled(true)
            case .done:
                Button("Re-run") {
                    Task {
                        recommendedThreshold = nil
                        noiseSamples = []
                        speechSamples = []
                        await runCalibration()
                    }
                }
                Button("Apply") { applyAndDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(recommendedThreshold == nil)
            }
        }
    }

    // MARK: - Mic priming

    private func primeMicForCalibration() {
        micWasEnabled = services.micEnabled
        if !services.micEnabled {
            // Toggle Listen on so the VU pump starts producing
            // RMS values. AppServices' toggle is async; the
            // calibration's `.intro` phase gives the audio chain
            // a moment to spin up before the user clicks Start.
            Task { await services.toggleMic() }
        }
    }

    private func restoreMicState() {
        // If the user had Listen off when they opened the sheet,
        // turn it off again so calibration is non-disruptive.
        if !micWasEnabled, services.micEnabled {
            Task { await services.toggleMic() }
        }
    }

    // MARK: - Capture loop

    private func runCalibration() async {
        // Quiet phase
        phase = .quiet
        noiseSamples = await collectRMS(for: quietSeconds)

        // Speak phase
        phase = .speak
        speechSamples = await collectRMS(for: speechSeconds)

        // Compute threshold
        recommendedThreshold = computeThreshold(
            noise: noiseSamples,
            speech: speechSamples
        )
        phase = .done
    }

    /// Polls services.lastMicRMS at 20 Hz for the duration. Returns
    /// every observed sample. The poll interval matches the VU
    /// pump's 10 Hz update plus a 2x oversample so the RMS log isn't
    /// stride-aliased.
    private func collectRMS(for seconds: Double) async -> [Float] {
        var samples: [Float] = []
        let intervalNs: UInt64 = 50_000_000   // 20 Hz
        let totalSamples = Int(seconds * 20)
        elapsed = 0
        let started = Date()
        for i in 0..<totalSamples {
            samples.append(services.lastMicRMS)
            elapsed = Date().timeIntervalSince(started)
            // Skip the trailing sleep on the last iteration —
            // the UI flips to the next phase as soon as we return.
            if i < totalSamples - 1 {
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
        return samples
    }

    // MARK: - Threshold math

    /// Compute a VAD threshold from the noise and speech RMS samples.
    ///
    /// The threshold has to live above the noise floor (so room
    /// hum doesn't keep the VAD latched on) and below the user's
    /// quietest speech (so quiet/distant words still trigger). We
    /// pick the geometric midpoint between `noise_max * 1.5` (some
    /// headroom over peak noise) and `speech_p25 * 0.5` (half the
    /// 25th-percentile speech RMS — well under any normal word),
    /// then clamp to a safe range.
    private func computeThreshold(
        noise: [Float],
        speech: [Float]
    ) -> Float? {
        guard !noise.isEmpty, !speech.isEmpty else { return nil }
        let noiseMax = noise.max() ?? 0
        let speechP25 = percentile(speech, 0.25)
        // Both phases produced effectively zero RMS — the mic
        // probably wasn't producing samples (Listen toggle still
        // spinning up, robot mic offline). Surface as failure so
        // the user re-runs rather than persisting a meaningless
        // threshold.
        let speechP50 = percentile(speech, 0.5)
        if noiseMax < 0.0001, speechP50 < 0.0001 { return nil }
        // If the user wasn't actually speaking (e.g. mic muted,
        // robot mic offline), speechP25 ≤ noiseMax; emit a
        // conservative fallback above noise rather than a tiny
        // threshold that would VAD-latch constantly.
        let lower = max(noiseMax * 1.5, 0.001)
        let upper = max(speechP25 * 0.5, lower * 1.001)
        let mid = (lower + upper) / 2
        // Hard clamp: never below 0.001 (would catch quantisation
        // noise) and never above 0.05 (would miss most speech).
        return min(max(mid, 0.001), 0.05)
    }

    /// Linear-interpolated percentile (matches numpy's default).
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
        guard let t = recommendedThreshold else { return }
        services.settings.micVADThreshold = Double(t)
        // Live-apply to the running VAD without waiting for the
        // next applySettings cycle.
        Task { await services.voice.setVADThreshold(t) }
        dismiss()
    }
}
