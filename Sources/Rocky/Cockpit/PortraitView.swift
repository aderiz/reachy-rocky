import AppKit
import SwiftUI

/// PortraitView — the stage's left column.
///
/// Per `docs/concepts/cockpit-design.md` §3.1, the portrait is the
/// visual centre of the app. The 3D head fills the column; underneath,
/// Rocky's name (`.title.weight(.semibold)`), a single sentence of
/// presence (`.callout`, secondary), and *one* primary action that
/// follows state.
///
/// State is read by anatomy, not by badges:
///   - eyes track when watching, blink when idle, slump in sleep,
///   - antennas tip on tracking, droop in sleep,
///   - the head pitches forward when speaking,
///
/// All driven by `services.lastRobotState` through the existing
/// `ReachyHead3D` view. We deliberately don't surface latency pills,
/// botMode badges, or tool-call counters here — those live in the
/// inspector. This column is for *reading Rocky as a being*.
struct PortraitView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            // Avatar plus two glass-overlay chips floating on its
            // upper corners — Rocky's senses framed onto Rocky's
            // presence. Per design: subordinate, instrument-like,
            // never occluding the antennas (we keep the chips inset
            // from the column edges + the head's vertical centre).
            ZStack(alignment: .topLeading) {
                head
                    .padding(.horizontal, 12)
                SensesChip()
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }
            Spacer(minLength: 0)
            namePlate
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            primaryAction
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Full-column gradient — the avatar itself is transparent so
        // antennas silhouette against the lighter crown of the
        // gradient as the column extends to the top of the window.
        // The stops descend through slate to near-black so the name
        // and primary action sit on dark, readable territory at the
        // base.
        .background(ReachyMiniAvatar.backdrop)
    }

    // MARK: - Head

    private var head: some View {
        ReachyMiniAvatar(
            state: services.rockyState,
            pose: services.lastRobotState?.headPose,
            antennas: services.lastRobotState?.antennasPosition,
            bodyYaw: services.lastRobotState?.bodyYaw,
            headJoints: services.lastRobotState?.headJoints,
            passiveJoints: services.lastRobotState?.passiveJoints
        )
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel(accessibilityState)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Name plate (the only typography on the stage)

    private var namePlate: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rocky")
                .font(.title.weight(.semibold))
            Text(presenceLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Single sentence describing what Rocky is doing right now. The
    /// same string lives in the menu-bar popover (so the two surfaces
    /// don't drift), but is computed here from `rockyState` directly so
    /// the views stay independently testable.
    private var presenceLine: String {
        if services.isDoNotDisturb,
           let until = services.dndUntil {
            let mins = max(1, Int(until.timeIntervalSinceNow / 60))
            return "Quiet mode for \(mins) more minute\(mins == 1 ? "" : "s")."
        }
        switch services.rockyState {
        case .sleeping:    return "Asleep — say his name to wake."
        case .waking:      return "Waking up…"
        case .idle:        return "Awake. No one's in front of him yet."
        case .tracking:
            if let name = services.lastFaceDetection?.identity {
                return "Watching \(name)."
            }
            return "Watching."
        case .listening:
            if let name = services.lastFaceDetection?.identity {
                return "Listening to \(name)."
            }
            return "Listening."
        case .thinking:    return "Thinking."
        case .speaking:    return "Speaking."
        case .error(let m): return m
        }
    }

    private var accessibilityState: String {
        "Rocky's head, animated. \(presenceLine)"
    }

    // MARK: - Primary action — one button, follows state

    /// Per the design doc: one primary action whose meaning follows the
    /// state. Wake when asleep, Sleep when awake; "Stop talking" wins
    /// while a TTS clip is playing because that's the most-likely thing
    /// you want to interrupt.
    @ViewBuilder
    private var primaryAction: some View {
        let primary = primaryActionDescriptor
        Button(action: primary.action) {
            HStack(spacing: 6) {
                Image(systemName: primary.icon)
                Text(primary.label)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(primary.tint)
        .keyboardShortcut(primary.shortcut.0, modifiers: primary.shortcut.1)
        .disabled(primary.disabled)
        .help(primary.tooltip)
    }

    private struct PrimaryAction {
        let label: String
        let icon: String
        let tint: Color
        let action: () -> Void
        let shortcut: (KeyEquivalent, EventModifiers)
        let disabled: Bool
        let tooltip: String
    }

    private var primaryActionDescriptor: PrimaryAction {
        // Mute-while-speaking takes precedence — that's the most-likely
        // thing you reach for the button to do mid-turn. (Real
        // mid-clip cancel needs daemon-side support; muting is the
        // user-visible equivalent for now.)
        if let busyUntil = services.ttsBusyUntil, Date() < busyUntil,
           !services.ttsMuted {
            return .init(
                label: "Stop talking",
                icon: "speaker.slash.fill",
                tint: .orange,
                action: { Task { await services.toggleTTSMute() } },
                shortcut: (".", [.command]),
                disabled: false,
                tooltip: "Mute Rocky's voice. ⌘."
            )
        }
        switch services.rockyState {
        case .sleeping, .error:
            return .init(
                label: "Wake him up",
                icon: "sun.max.fill",
                tint: .accentColor,
                action: { Task { await services.wakeRobot() } },
                shortcut: (.return, []),
                disabled: false,
                tooltip: "Enable motors and recover the neutral pose. ⏎"
            )
        case .waking:
            return .init(
                label: "Waking…",
                icon: "hourglass",
                tint: .secondary,
                action: {},
                shortcut: (.return, []),
                disabled: true,
                tooltip: "Rocky is currently waking up."
            )
        case .idle, .tracking, .listening, .thinking, .speaking:
            return .init(
                label: "Send him to sleep",
                icon: "moon.fill",
                tint: .indigo,
                action: { Task { await services.sleepRobot() } },
                shortcut: (.return, [.shift]),
                disabled: false,
                tooltip: "Disable motors after the goodbye animation. ⇧⏎"
            )
        }
    }
}

// MARK: - Senses overlays

/// A small bottom-right "grip" the user drags to resize a chip in
/// 2-D. Held by both `VisionChip` and `EarsChip`. Translation is
/// applied against the size at gesture start so the chip tracks the
/// cursor 1:1 without exponential drift. Bounds are clamped at the
/// caller; the grip itself just reports raw deltas + commits the
/// final size to settings on release.
private struct ResizeGrip: View {
    @Binding var size: CGSize
    let minSize: CGSize
    let maxSize: CGSize
    let onCommit: (CGSize) -> Void

    @State private var dragStartSize: CGSize?

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
            .padding(4)
            .background(
                Circle().fill(.black.opacity(0.45))
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartSize == nil { dragStartSize = size }
                        guard let start = dragStartSize else { return }
                        let w = min(maxSize.width,
                                    max(minSize.width,
                                        start.width + value.translation.width))
                        let h = min(maxSize.height,
                                    max(minSize.height,
                                        start.height + value.translation.height))
                        size = CGSize(width: w, height: h)
                    }
                    .onEnded { _ in
                        dragStartSize = nil
                        onCommit(size)
                    }
            )
            .help("Drag to resize")
    }
}

/// Senses chip — combined eyes + ears in one floating viewport.
///
/// Layout (z-axis, back to front):
///   1. Live camera JPEG fills the chip (or `eye.slash` fallback
///      when the camera is off / vision is disabled / no frame yet).
///   2. A linear gradient scrim along the bottom of the chip
///      darkens the video so the audio overlay reads against any
///      lighting.
///   3. Inside the scrim: a small scrolling waveform sampled from
///      `services.lastMicRMS` at ~30 Hz, with the rolling STT
///      partial in italic .caption underneath.
///
/// The chip is resizable in 2-D via a corner grip that fades in on
/// hover. Size is persisted via `SettingsStore` and survives
/// relaunches. Defaults to a 16:9 size matching the relay's typical
/// output so the first frame fits cleanly.
private struct SensesChip: View {
    @Environment(AppServices.self) private var services

    private static let minSize = CGSize(width: 140, height: 96)
    private static let maxSize = CGSize(width: 560, height: 360)
    /// 2.5 s of history at 20 Hz — 50 fatter bars instead of the
    /// previous 90 thin ones. Voice-Memos-style: each bar gets
    /// room to breathe + a true capsule shape, so the wave reads
    /// as a wave instead of noise.
    private static let sampleCount = 50
    private static let sampleHz: Double = 20
    /// Visual amplification — typical voice RMS is in the
    /// 0.02–0.15 range; raw scale would render as a barely-there
    /// twitch. Clamped to 1.0 so loud audio still fits the canvas.
    private static let waveformGain: Float = 6.5

    @State private var size: CGSize = .init(width: 240, height: 150)
    @State private var samples: [Float] = Array(repeating: 0, count: 50)
    @State private var hovering: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack(alignment: .bottom) {
                videoLayer
                bottomScrim
                audioOverlay
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .shadow(color: .black.opacity(0.30), radius: 8, y: 3)

            ResizeGrip(
                size: $size,
                minSize: Self.minSize,
                maxSize: Self.maxSize,
                onCommit: { final in
                    services.settings.visionChipWidth = final.width
                    services.settings.visionChipHeight = final.height
                }
            )
            .opacity(hovering ? 1.0 : 0.0)
            .padding(4)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .onAppear {
            size = CGSize(width: services.settings.visionChipWidth,
                          height: services.settings.visionChipHeight)
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .help("What Rocky sees and hears. Hover to reveal the resize grip.")
        .task {
            let interval = UInt64(1_000_000_000 / Self.sampleHz)
            while !Task.isCancelled {
                let rms = services.lastMicRMS
                samples.append(rms)
                if samples.count > Self.sampleCount {
                    samples.removeFirst(samples.count - Self.sampleCount)
                }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private var videoLayer: some View {
        if services.visionEnabled,
           let frame = services.lastCameraFrame,
           let nsImage = NSImage(data: frame.jpeg) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            ZStack {
                Rectangle().fill(.black.opacity(0.30))
                Image(systemName: services.visionEnabled ? "eye" : "eye.slash")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// Linear gradient scrim from transparent (top) → ~50 % black
    /// (mid) → ~88 % black (bottom). Three stops instead of two
    /// so the lower portion (where the waveform + STT sit) stays
    /// clearly readable even over bright / busy footage; the top
    /// of the scrim still fades softly into the live video. Height
    /// is proportional to the chip so the band scales with resize.
    private var bottomScrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.0),  location: 0.0),
                .init(color: .black.opacity(0.50), location: 0.40),
                .init(color: .black.opacity(0.88), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: max(48, size.height * 0.48))
        .allowsHitTesting(false)
    }

    private var audioOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Canvas { ctx, canvasSize in
                drawWaveform(ctx: ctx, size: canvasSize, samples: samples,
                             micOn: services.micEnabled)
            }
            .frame(height: max(16, min(40, size.height * 0.18)))

            Text(captionText)
                .font(.caption.italic())
                .foregroundStyle(captionTint)
                .shadow(color: .black.opacity(0.6), radius: 1, y: 0)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .padding(.top, 6)
        .allowsHitTesting(false)
    }

    // MARK: - Audio caption + a11y

    private var captionText: String {
        if !services.micEnabled { return "Mic off." }
        let t = services.lastTranscript
        if t.isEmpty {
            return services.conversationOpenUntil != nil
                ? "Listening…"
                : "Say Rocky."
        }
        return "\u{201C}\(t)\u{201D}"
    }

    private var captionTint: Color {
        services.lastTranscript.isEmpty
            ? Color.white.opacity(0.6)
            : Color.white.opacity(0.95)
    }

    private var accessibilityText: String {
        let visionState = services.visionEnabled
            ? "Camera live"
            : "Camera disabled"
        let audioState = services.micEnabled
            ? (services.lastTranscript.isEmpty
                ? "listening"
                : "hearing: \(services.lastTranscript)")
            : "mic off"
        return "Rocky senses chip. \(visionState). \(audioState)."
    }

    // MARK: - Waveform

    /// Draw the rolling waveform as a smooth flowing ribbon
    /// mirrored around the centreline, filled with a per-sample
    /// horizontal gradient keyed by RMS.
    ///
    /// Composition (back to front):
    ///   1. Faint centreline at ~10 % white so the wave shape is
    ///      anchored even when the signal is silent.
    ///   2. Soft outer glow: the same ribbon path rendered into a
    ///      blurred offscreen layer, sits underneath so the wave
    ///      reads with depth.
    ///   3. Crisp ribbon: closed path traced by smoothed
    ///      quadratic-Bezier curves through each sample's top
    ///      point + the mirror of those points along the bottom.
    ///      Filled with a horizontal `LinearGradient` whose stops
    ///      are computed per sample — each stop is the RMS-keyed
    ///      colour (cyan → green → yellow → red lerp) at that
    ///      moment, with an age-based opacity ramp so older
    ///      samples (left) fade and newest (right) is brightest.
    ///
    /// The result: a continuous coloured ribbon that grows
    /// symmetrically from the centre outward as you speak, with
    /// the hue along its length reflecting the loudness contour of
    /// the utterance over time.
    private func drawWaveform(
        ctx: GraphicsContext,
        size: CGSize,
        samples: [Float],
        micOn: Bool
    ) {
        guard samples.count >= 2 else { return }
        let n = samples.count
        let midY = size.height / 2
        let stepX = size.width / CGFloat(n - 1)
        let maxHalfH = size.height * 0.42

        // 1. Faint centreline.
        ctx.fill(
            Path(CGRect(x: 0, y: midY - 0.5, width: size.width, height: 1)),
            with: .color(.white.opacity(0.10))
        )

        // Top points (y above midline), one per sample. Floor at
        // ~2pt so even silent samples leave a hairline ribbon
        // rather than collapsing to a single line segment.
        let topPoints: [CGPoint] = samples.enumerated().map { idx, s in
            let amp = CGFloat(min(1.0, max(0.0, s * Self.waveformGain)))
            let halfH = max(1.5, amp * maxHalfH)
            return CGPoint(x: CGFloat(idx) * stepX, y: midY - halfH)
        }

        // Build the closed ribbon path: smooth top curve →
        // right-edge drop to midY → mirrored bottom curve →
        // left-edge return to midY → close.
        var ribbon = Path()
        ribbon.move(to: CGPoint(x: topPoints.first!.x, y: midY))
        ribbon.addLine(to: topPoints[0])
        for i in 1..<n {
            let prev = topPoints[i - 1]
            let curr = topPoints[i]
            // Quadratic Bezier from prev to the midpoint of prev/curr,
            // using prev as the control — a cheap Catmull-Rom-ish
            // smoothing that softens corners without much overhead.
            let mid = CGPoint(x: (prev.x + curr.x) / 2,
                              y: (prev.y + curr.y) / 2)
            ribbon.addQuadCurve(to: mid, control: prev)
        }
        ribbon.addLine(to: topPoints.last!)
        ribbon.addLine(to: CGPoint(x: topPoints.last!.x, y: midY))
        // Mirror the top into the bottom (high y values), walking
        // right to left to close the polygon.
        for i in stride(from: n - 1, through: 0, by: -1) {
            let t = topPoints[i]
            ribbon.addLine(to: CGPoint(x: t.x, y: midY + (midY - t.y)))
        }
        ribbon.closeSubpath()

        // 3-stop-per-sample horizontal gradient — each sample
        // contributes its own RMS-keyed colour with an age fade,
        // so the ribbon's hue along its length traces the
        // loudness contour over time.
        let stops: [Gradient.Stop] = samples.enumerated().map { idx, s in
            let base: Color = micOn
                ? Self.colorForRMS(max(0, s))
                : Color.white
            let progress = Double(idx) / Double(max(1, n - 1))
            // Age fade: oldest sample lands at 35% alpha, newest
            // at 100%. The wave "trails off" to the left without
            // ever fully disappearing.
            let alpha = 0.35 + 0.65 * progress
            return Gradient.Stop(color: base.opacity(alpha),
                                 location: progress)
        }
        let gradient = Gradient(stops: stops)
        let fillStart = CGPoint(x: 0, y: midY)
        let fillEnd = CGPoint(x: size.width, y: midY)

        // 2. Outer glow layer — same path, blurred, sits under
        //    the crisp fill. Adds the "Siri ribbon" softness.
        ctx.drawLayer { glow in
            glow.addFilter(.blur(radius: 5))
            glow.fill(
                ribbon,
                with: .linearGradient(
                    gradient,
                    startPoint: fillStart,
                    endPoint: fillEnd
                )
            )
        }

        // 3. Crisp ribbon on top.
        ctx.fill(
            ribbon,
            with: .linearGradient(
                gradient,
                startPoint: fillStart,
                endPoint: fillEnd
            )
        )
    }

    /// Smooth RGB-interpolated colour ramp keyed on the raw RMS
    /// amplitude. Anchor stops are tuned to perceptual loudness
    /// rungs we see in practice on the ReSpeaker / Mac mic:
    ///
    ///   - 0.00  cyan       (near silence)
    ///   - 0.05  green      (speech floor)
    ///   - 0.18  yellow     (strong speech)
    ///   - 0.40+ red        (loud / clipping headroom)
    ///
    /// Between stops the colour is linearly interpolated in RGB so
    /// adjacent samples shade smoothly — the wave reads as a
    /// continuous gradient rather than four flat bands.
    private static let rmsStops: [(threshold: Float,
                                   r: Double, g: Double, b: Double)] = [
        (0.000, 0.35, 0.85, 1.00),  // deep cyan — near silence
        (0.020, 0.35, 0.95, 0.55),  // bright green — speech floor
        (0.060, 1.00, 0.85, 0.25),  // amber — conversational
        (0.140, 1.00, 0.50, 0.25),  // orange — strong speech
        (0.260, 1.00, 0.30, 0.35),  // red — loud / clipping headroom
    ]

    private static func colorForRMS(_ rms: Float) -> Color {
        let value = max(0, rms)
        // Clamp below the first stop to its colour.
        if value <= rmsStops.first!.threshold {
            let s = rmsStops.first!
            return Color(red: s.r, green: s.g, blue: s.b)
        }
        // Clamp at or above the last stop.
        if value >= rmsStops.last!.threshold {
            let s = rmsStops.last!
            return Color(red: s.r, green: s.g, blue: s.b)
        }
        // Otherwise lerp between the two surrounding stops.
        for i in 0..<(rmsStops.count - 1) {
            let lo = rmsStops[i]
            let hi = rmsStops[i + 1]
            if value >= lo.threshold && value <= hi.threshold {
                let span = hi.threshold - lo.threshold
                let t = span > 0
                    ? Double((value - lo.threshold) / span)
                    : 0
                return Color(
                    red:   lo.r + (hi.r - lo.r) * t,
                    green: lo.g + (hi.g - lo.g) * t,
                    blue:  lo.b + (hi.b - lo.b) * t
                )
            }
        }
        // Unreachable (clamps above cover all cases) but the
        // compiler can't prove that, so return a sensible fallback.
        let s = rmsStops.last!
        return Color(red: s.r, green: s.g, blue: s.b)
    }
}

