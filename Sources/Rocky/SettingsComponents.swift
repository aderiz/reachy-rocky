import SwiftUI
import SidecarHost

/// Reusable SwiftUI primitives for the Settings window.
///
/// One file holds the small components shared across sections (Brain,
/// Listen, Speak, Memory, Faces) so the section files themselves stay
/// focused on their domain and don't re-implement the same patterns
/// with slight visual drift. `StatusPill` itself lives in
/// `UI/Card.swift` (it's used outside Settings too); the convenience
/// initialisers and engine-specific helpers live here.

// MARK: - StatusPill sidecar projection

/// Pure-function projection of a `SidecarState` into a StatusPill.
/// Centralises the "this is what 'ready' looks like" mapping so every
/// sidecar reads visually identically across the whole settings UI.
extension StatusPill {
    init(sidecar state: SidecarState, readyLabel: String = "Ready") {
        switch state {
        case .ready:
            self.init(intent: .ok, text: readyLabel)
        case .starting:
            // pulse: true so the hourglass animates while we wait —
            // tells the user the sidecar is doing work, not stuck.
            self.init(intent: .pending, text: "Starting…", pulse: true)
        case .stopped:
            self.init(intent: .dormant, text: "Not running")
        case .failing(let r):
            self.init(intent: .warn, text: "Failing: \(r)")
        case .circuitOpen(let until):
            self.init(
                intent: .warn,
                text: "Cooldown until \(until.formatted(.dateTime.hour().minute().second()))"
            )
        }
    }
}

// Add `pulse` to the intent-based init so callers can opt in.
extension StatusPill {
    init(intent: Intent, text: String, systemImage: String? = nil, pulse: Bool) {
        self.text = text
        self.tint = intent.tint
        self.systemImage = systemImage ?? intent.defaultIcon
        self.pulse = pulse
    }
}

// MARK: - EnginePicker

/// One-shot pattern for "pick an engine, see what's actually active,
/// optionally restart it". Used by Brain (MLX-VLM vs LM Studio), STT
/// (Apple/MLX/WhisperKit), VAD (Silero/Energy), and TTS (Chatterbox/
/// Qwen3/Fish). Before this component, each section reinvented the
/// same picker+status+restart layout — drift was creeping in
/// (different label widths, different pill placement, different
/// footer styles).
///
/// Designed to slot directly into a `Section` inside a `Form`. The
/// caller supplies:
///   - `title`              — section heading
///   - `selection`          — the user's *preferred* engine tag
///   - `options`            — (tag, label) pairs for the picker
///   - `activePill`         — what's *actually* running. Caller resolves
///                            this from the relevant `services.*`
///                            published property (sttBackendName,
///                            brainSidecarState, etc.).
///   - `onChange`           — fired when the user changes the picker.
///                            Caller writes to `settings` + triggers
///                            any apply work.
///   - `restart`            — optional async closure for a Restart
///                            button (Brain has one; STT/TTS apply on
///                            next launch so they don't).
///   - `footer`             — short summary line. Long prose goes
///                            behind a "Learn more…" disclosure
///                            (built-in here).
///   - `learnMore`          — optional long-form text revealed by
///                            the disclosure.
struct EnginePicker<Tag: Hashable, Active: View>: View {
    let title: String
    @Binding var selection: Tag
    let options: [(tag: Tag, label: String)]
    @ViewBuilder let activeBadge: () -> Active
    var restart: (@Sendable () async -> Void)? = nil
    var footer: String
    var learnMore: String? = nil

    @State private var expanded: Bool = false

    var body: some View {
        Section {
            Picker("Preferred", selection: $selection) {
                ForEach(options, id: \.tag) { opt in
                    Text(opt.label).tag(opt.tag)
                }
            }
            HStack {
                Text("Active")
                    .foregroundStyle(.secondary)
                Spacer()
                activeBadge()
                if let restart {
                    Button {
                        Task { await restart() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Restart this engine")
                }
            }
        } header: {
            Text(title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let learnMore {
                    DisclosureGroup(isExpanded: $expanded) {
                        Text(learnMore)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    } label: {
                        Text(expanded ? "Less" : "Learn more")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
    }
}

// MARK: - LabeledSlider

/// A slider row with a left-aligned label, a right-aligned monospaced
/// value readout, and an inline helper. Replaces the hand-rolled
/// `VStack { HStack { SectionLabel; Spacer; Text } Slider Text }`
/// pattern that appeared in MicSensitivityRow / BotVolumeSlider /
/// FaceMatchThresholdSlider / MemoryTopKSlider with consistent
/// spacing.
struct LabeledSlider<V: BinaryFloatingPoint>: View
where V.Stride: BinaryFloatingPoint {
    let title: String
    @Binding var value: V
    let range: ClosedRange<V>
    var step: V.Stride = 0
    var format: (V) -> String = { v in String(format: "%.2f", Double(v)) }
    var minimumLabel: String? = nil
    var maximumLabel: String? = nil
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.callout)
                Spacer()
                // `.contentTransition(.numericText())` morphs digits
                // when the slider value changes — smoother than the
                // default text-swap which flashes between values.
                Text(format(value))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: value)
                    .foregroundStyle(.primary)
            }
            slider
            if let help {
                Text(help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var slider: some View {
        if step > 0 {
            Slider(value: $value, in: range, step: step) {
                Text(title)
            } minimumValueLabel: {
                labelView(minimumLabel)
            } maximumValueLabel: {
                labelView(maximumLabel)
            }
        } else {
            Slider(value: $value, in: range) {
                Text(title)
            } minimumValueLabel: {
                labelView(minimumLabel)
            } maximumValueLabel: {
                labelView(maximumLabel)
            }
        }
    }

    @ViewBuilder
    private func labelView(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            EmptyView()
        }
    }
}

// MARK: - VU meter

/// Live, scrolling 3-second waveform of the mic RMS with the VAD
/// threshold drawn as a horizontal guide. Genuine SwiftUI craft —
/// `TimelineView(.animation)` drives a 30 fps redraw, `Canvas`
/// renders bars proportional to the rolling RMS history. Bars above
/// the threshold tint green, bars below tint secondary — so the
/// user can SEE whether their voice is reliably crossing the line
/// instead of squinting at a printed number.
///
/// `samples` is a ring buffer of recent RMS values; the view itself
/// doesn't sample (that's the caller's job — `MicSensitivityRow`
/// pushes one sample per TimelineView tick).
///
/// Named `MicVUMeter` to disambiguate from the simpler single-bar
/// `VUMeter` in `ConversationView.swift` (used as a tiny mic-level
/// indicator next to the listen toggle).
struct MicVUMeter: View {
    /// Current RMS — the rightmost (newest) sample in the rolling
    /// window.
    let current: Float
    /// Threshold to draw as a horizontal line. Bars exceeding this
    /// tint green; below tint secondary.
    let threshold: Float
    /// Rolling history of RMS values, oldest → newest. The view
    /// renders one bar per sample left-to-right.
    let history: [Float]
    /// Maximum RMS the meter will display before clipping. RMS in
    /// quiet rooms tops out around 0.05–0.10 for normal speech; the
    /// VAD threshold range is 0.001–0.05, so we display up to 0.06
    /// (roughly 1.2× the slider max) for comfortable headroom.
    var displayMax: Float = 0.06

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let n = max(1, history.count)
            let barW = w / CGFloat(n)
            let gap: CGFloat = barW > 3 ? 1 : 0

            // Threshold guide line — drawn first so bars overlay it.
            let thresholdY = h - h * CGFloat(min(threshold, displayMax) / displayMax)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: thresholdY))
            line.addLine(to: CGPoint(x: w, y: thresholdY))
            ctx.stroke(
                line,
                with: .color(.orange.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )

            // Bars.
            for (i, sample) in history.enumerated() {
                let clamped = min(max(sample, 0), displayMax)
                let barH = h * CGFloat(clamped / displayMax)
                let x = CGFloat(i) * barW
                let rect = CGRect(
                    x: x + gap * 0.5,
                    y: h - barH,
                    width: max(0.5, barW - gap),
                    height: max(0.5, barH)
                )
                let above = sample >= threshold
                let color: GraphicsContext.Shading = above
                    ? .color(.green.opacity(0.85))
                    : .color(.secondary.opacity(0.40))
                ctx.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: color
                )
            }
        }
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
        .overlay(alignment: .topTrailing) {
            // Live numeric badge, top-right corner. ContentTransition
            // animates the digits as they change instead of flickering.
            Text(String(format: "%.4f", current))
                .font(.caption2.monospacedDigit().weight(.medium))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: current)
                .foregroundStyle(current >= threshold ? .green : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 4))
                .padding(4)
        }
    }
}

// MARK: - LearnMoreFooter

/// Free-standing footer with progressive disclosure. Use inside any
/// `Section { ... } footer: { LearnMoreFooter(...) }` to keep the
/// section visually compact while still surfacing detail on demand.
struct LearnMoreFooter: View {
    let summary: String
    var detail: String? = nil

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let detail {
                DisclosureGroup(isExpanded: $expanded) {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } label: {
                    Text(expanded ? "Less" : "Learn more")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}
