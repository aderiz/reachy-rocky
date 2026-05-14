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
    @Environment(\.colorScheme) private var colorScheme

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
                // Sleeping Z's float above the head while asleep.
                // Sits BETWEEN head and the chips so the chips
                // remain visible/tappable. `.allowsHitTesting(false)`
                // inside SleepingZs keeps the Canvas non-interactive.
                if services.isAsleep {
                    SleepingZs()
                        .padding(.horizontal, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
                SensesChip()
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                // Power chip on the opposite corner so it balances the
                // SensesChip and stays clear of the antennas. iOS-style
                // pill glyph + percent (or voltage on DC); auto-hides
                // when there's no signal.
                PowerChipOverlay()
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }
            .animation(.easeInOut(duration: 0.45), value: services.isAsleep)
            Spacer(minLength: 0)
            namePlate
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
        .background(ReachyMiniAvatar.backdrop(for: colorScheme))
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rocky")
                    .font(.title.weight(.semibold))
                Text(presenceLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            wakeToggle
        }
    }

    // MARK: - Wake / sleep slider switch

    /// Sliding switch styled after iOS-system day/night toggles. The
    /// track tint, end-cap icons (sun ⇄ moon), and the circular thumb
    /// all flow together to express the current state. ⏎ flips it;
    /// the thumb slides between ends with a spring.
    ///
    /// Conventions:
    ///   - Awake → thumb on the LEFT, sun glyph highlighted, amber track.
    ///   - Asleep → thumb on the RIGHT, moon glyph highlighted, indigo track.
    ///   - Waking → muted track + ghosted thumb; switch is disabled
    ///     so it can't be slammed during the wake animation.
    private var wakeToggle: some View {
        WakeSleepSwitch(
            isAwake: isAwake,
            isTransitioning: services.rockyState == .waking
        ) {
            Task {
                if isAwake { await services.sleepRobot() }
                else { await services.wakeRobot() }
            }
        }
        .keyboardShortcut(.return, modifiers: [])
        .help(isAwake
              ? "Send Rocky to sleep. ⏎"
              : "Wake Rocky up. ⏎")
        .accessibilityLabel(isAwake ? "Awake — tap to sleep" : "Asleep — tap to wake")
    }

    /// Mirror the state-machine into a binary awake/asleep view of
    /// the toggle. The waking transition reads as "still asleep" so
    /// the switch only flips on once the wake sequence completes.
    private var isAwake: Bool {
        switch services.rockyState {
        case .sleeping, .waking, .error: return false
        case .idle, .tracking, .listening, .thinking, .speaking: return true
        }
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

}

// MARK: - Wake / sleep switch

/// iOS-style sliding switch for Rocky's wake state.
///
/// Awake = "on": GREEN track, thumb on the RIGHT (iOS standard).
/// Asleep = "off": near-black track, thumb on the LEFT.
///
/// End-cap glyphs: moon on the LEFT (asleep position), sun on the
/// RIGHT (awake position) so the thumb always sits over the icon
/// representing the *current* state.
private struct WakeSleepSwitch: View {
    let isAwake: Bool
    let isTransitioning: Bool
    let onTap: () -> Void

    private let trackW: CGFloat = 64
    private let trackH: CGFloat = 32
    private let thumbSize: CGFloat = 26
    private let inset: CGFloat = 3

    // iOS Settings.app green for "on" (awake); near-black for "off"
    // (asleep). Same hue family as Focus / system toggles.
    private static let onTint = Color(red: 0.20, green: 0.78, blue: 0.35)
    private static let offTint = Color(red: 0.11, green: 0.11, blue: 0.13)

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .leading) {
                track
                endCaps
                thumb
            }
            .frame(width: trackW, height: trackH)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isTransitioning)
        .animation(.spring(response: 0.28, dampingFraction: 0.78),
                   value: isAwake)
        .opacity(isTransitioning ? 0.55 : 1.0)
    }

    private var trackFill: Color { isAwake ? Self.onTint : Self.offTint }

    private var track: some View {
        Capsule()
            .fill(trackFill)
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.8)
            )
    }

    /// Moon on the asleep (left) end, sun on the awake (right) end.
    /// The thumb sits over the icon of the current state — moon when
    /// asleep, sun when awake. The opposite end's glyph fades to 0
    /// so only one icon is visible at a time, behind the thumb.
    private var endCaps: some View {
        HStack {
            Image(systemName: "moon.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(isAwake ? 0.50 : 0.0))
            Spacer()
            Image(systemName: "sun.max.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(isAwake ? 0.0 : 0.50))
        }
        .padding(.horizontal, 9)
        .frame(width: trackW, height: trackH)
    }

    private var thumb: some View {
        ZStack {
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            Image(systemName: isAwake ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 13, weight: .bold))
                // Dark slate — high contrast on the white thumb in
                // either state. Track colour around it carries the
                // semantic (green = awake).
                .foregroundStyle(Color(red: 0.18, green: 0.20, blue: 0.24))
        }
        .frame(width: thumbSize, height: thumbSize)
        // Awake = thumb on RIGHT (iOS "on" position).
        // Asleep = thumb on LEFT.
        .offset(x: isAwake ? (trackW - thumbSize - inset) : inset)
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
    /// When the asleep→awake edge was observed. While non-nil, the
    /// video chip animates a "waking eye" sequence: shutter opens
    /// from above, a few bleary blinks, blur radius eases from 18
    /// to 0 (frames sharpen). Cleared by the .task that auto-fires
    /// after the wake animation duration elapses.
    @State private var wakeStartedAt: Date? = nil
    /// Total duration of the waking sequence (s). Paced for a slow,
    /// heavy wake: the lids barely move for the first second
    /// (eyes-still-shut hold), then begin to crack, blink several
    /// times during the head's movement, and continue to focus
    /// well after the head has arrived. Blur clears across the
    /// whole window, so the picture is still slightly soft at the
    /// end of the sequence.
    private static let wakeDurationS: TimeInterval = 6.0

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
        // Detect asleep→awake edge so we can play the waking-eye
        // sequence. The edge fires once per wake; if the user
        // toggles wake/sleep rapidly the animation simply restarts.
        .onChange(of: services.isAsleep, initial: false) { wasAsleep, isAsleep in
            if wasAsleep, !isAsleep {
                wakeStartedAt = Date()
            }
        }
        // Auto-clear the wake animation after its duration. Bound
        // to wakeStartedAt as the task id so a fresh wake during an
        // in-flight animation restarts cleanly.
        .task(id: wakeStartedAt) {
            guard wakeStartedAt != nil else { return }
            try? await Task.sleep(nanoseconds:
                UInt64(Self.wakeDurationS * 1_000_000_000))
            await MainActor.run { wakeStartedAt = nil }
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
        // Three states:
        //   1. asleep → solid black (no frame, no chrome).
        //   2. waking → the eye-opening sequence: shutter rises from
        //      above, two bleary blinks, blur eases from 18 → 0.
        //   3. awake (normal) → frame at full sharpness.
        if services.isAsleep {
            Rectangle()
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
        } else if let start = wakeStartedAt {
            wakingVideoLayer(start: start)
        } else {
            normalVideoLayer
        }
    }

    /// Normal awake state — sharp camera frame or placeholder.
    @ViewBuilder
    private var normalVideoLayer: some View {
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

    /// Eye-opening waking sequence. Driven by a TimelineView so
    /// shutter + blur stay frame-locked together (using
    /// withAnimation across two different effects produces visible
    /// drift between them). The frame underneath is the live
    /// camera image; two black eyelid bars — one descending from
    /// the top, one rising from the bottom — meet at the centre
    /// when closed and retract to the edges when open. Reads as
    /// a person cracking their eyes open, blinking against the
    /// light, and gradually focusing while their head settles
    /// into position.
    @ViewBuilder
    private func wakingVideoLayer(start: Date) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            let openness = Self.shutterOpenness(elapsed: elapsed)
            let blurRadius = Self.blurAmount(elapsed: elapsed)
            let brightnessLift = Self.brightnessLift(elapsed: elapsed)
            // Each lid covers half the frame when fully closed.
            let lidHeight = max(0, size.height * 0.5 * (1 - openness))

            ZStack {
                // Behind the shutter: the frame (or placeholder),
                // blurred + slightly desaturated + brightened.
                // Saturation eases back to 1.0 over the first 60 %
                // of the window so colour returns as the eye
                // settles.
                normalVideoLayer
                    .blur(radius: blurRadius)
                    // Saturation drop lingers through 75 % of the
                    // window — colour returns slowly, mirroring the
                    // brightness lift curve. The 0.40 maximum drop
                    // (vs. 0.35 before) makes the early haze read as
                    // more drained.
                    .saturation(
                        1.0 - 0.40 * max(0, 1.0 - elapsed / (Self.wakeDurationS * 0.80))
                    )
                    .brightness(brightnessLift)
                    .frame(width: size.width, height: size.height)
                    .clipped()

                // Top eyelid: anchored to the top edge, descends
                // toward the centre. Soft shadow at its leading
                // (bottom) edge so it reads as an eyelid rather
                // than a hard rectangle.
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: size.width, height: lidHeight)
                        .overlay(alignment: .bottom) {
                            LinearGradient(
                                colors: [
                                    .black.opacity(0.0),
                                    .black.opacity(0.55),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 14)
                            .blur(radius: 3)
                            .offset(y: 0)
                        }
                    Spacer(minLength: 0)
                }

                // Bottom eyelid: mirrored — anchored to the bottom
                // edge, rises toward the centre.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: size.width, height: lidHeight)
                        .overlay(alignment: .top) {
                            LinearGradient(
                                colors: [
                                    .black.opacity(0.55),
                                    .black.opacity(0.0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 14)
                            .blur(radius: 3)
                        }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    // MARK: - Waking curves
    //
    // All curves are pure functions of elapsed time since the wake
    // edge. Timeline (6.0 s total) is paced for a deliberately
    // heavy wake — long "still-asleep" hold before the first
    // crack, slow blink rhythm, blur clearing across the whole
    // window:
    //
    //   0.00–1.00 s : lids 0 → 10 %          (deep-sleep hold)
    //   1.00–1.40 s : lids 10 → 30 %         (first slow crack)
    //   1.40–1.80 s : lids 30 → 12 %         (first slow blink)
    //   1.80–2.60 s : lids 12 → 55 %         (long opening hold)
    //   2.60–3.00 s : lids 55 → 35 %         (second slow blink)
    //   3.00–3.90 s : lids 35 → 80 %         (continued opening)
    //   3.90–4.25 s : lids 80 → 65 %         (third blink)
    //   4.25–5.20 s : lids 65 → 100 %        (final opening)
    //   5.20–6.00 s : lids 100 %             (long focus settle tail)
    //
    // The first second is intentionally near-static — eyes almost
    // shut, the user reads "Rocky is still waking up." Blinks
    // through 4.25 s; final opening completes at 5.2 s; the last
    // 0.8 s holds the picture stable so the user has time to
    // perceive it as "ready."

    private static func shutterOpenness(elapsed: TimeInterval) -> Double {
        switch elapsed {
        case ..<1.00:
            // Very slow initial crack — barely visible movement.
            let t = easeOutCubic(elapsed / 1.00)
            return 0.10 * t                  // 0 → 0.10
        case 1.00..<1.40:
            let t = easeOutCubic((elapsed - 1.00) / 0.40)
            return 0.10 + 0.20 * t           // 0.10 → 0.30
        case 1.40..<1.80:
            let t = (elapsed - 1.40) / 0.40
            return 0.30 - 0.18 * t           // 0.30 → 0.12 (slow blink down)
        case 1.80..<2.60:
            let t = easeOutCubic((elapsed - 1.80) / 0.80)
            return 0.12 + 0.43 * t           // 0.12 → 0.55
        case 2.60..<3.00:
            let t = (elapsed - 2.60) / 0.40
            return 0.55 - 0.20 * t           // 0.55 → 0.35
        case 3.00..<3.90:
            let t = easeOutCubic((elapsed - 3.00) / 0.90)
            return 0.35 + 0.45 * t           // 0.35 → 0.80
        case 3.90..<4.25:
            let t = (elapsed - 3.90) / 0.35
            return 0.80 - 0.15 * t           // 0.80 → 0.65 (gentle)
        case 4.25..<5.20:
            let t = easeOutCubic((elapsed - 4.25) / 0.95)
            return 0.65 + 0.35 * t           // 0.65 → 1.00
        default:
            return 1.0
        }
    }

    private static func blurAmount(elapsed: TimeInterval) -> CGFloat {
        // Blur clears across the FULL window with a sine ease —
        // even at 4.0 s the picture is still noticeably soft, only
        // crisping in the final stretch. This is "the world is
        // coming into focus slowly", not "blur snaps off."
        guard elapsed < wakeDurationS else { return 0 }
        let t = elapsed / wakeDurationS
        // Sine ease: very slow start (heavy blur held), gentle
        // through the middle, slow finish too. Pairs with the
        // shutter so the blur is still significant during blinks.
        let eased = (cos(t * .pi) + 1) / 2  // 1 → 0 along a half-cosine
        return 26.0 * CGFloat(eased)
    }

    private static func brightnessLift(elapsed: TimeInterval) -> Double {
        // Linger through 80 % of the window — washed-out look
        // stays through both blink phases and into the final
        // opening, fading just before the settle tail.
        let span = wakeDurationS * 0.80
        guard elapsed < span else { return 0 }
        let t = elapsed / span
        return 0.14 * (1.0 - easeOutQuart(t))
    }

    private static func easeOutCubic(_ t: Double) -> Double {
        let clamped = max(0.0, min(1.0, t))
        return 1.0 - pow(1.0 - clamped, 3)
    }

    private static func easeOutQuart(_ t: Double) -> Double {
        let clamped = max(0.0, min(1.0, t))
        return 1.0 - pow(1.0 - clamped, 4)
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

// MARK: - Sleeping Z's overlay

/// Floating "Z" particles drifting above Rocky's 3D head while
/// `services.isAsleep`. The cockpit communicates dormancy through
/// the avatar itself (slumped head, drooping antennas via the
/// existing `RockyState`-driven rig) plus this comic-book sleep
/// glyph sitting just above and to the side of the head.
///
/// Design intent — "high quality" means:
///   • Smooth continuous motion (a `TimelineView` driving a
///     `Canvas` so the animation is frame-accurate and survives
///     SwiftUI's diffing — no `withAnimation` stutter).
///   • Each Z is its own particle with independent birth, motion,
///     and death — not three views sharing a single timeline.
///   • Organic drift: each Z rises on a slight rightward arc, not
///     a straight line, with a sinusoidal sway. The font scales
///     subtly as it rises, and rotation eases off-axis.
///   • Glow: a wider blurred underlayer behind each Z produces a
///     soft halo that reads as "dreamy."
///   • Easing: opacity follows a cubic-Hermite curve (fast fade-in,
///     long visible mid, fast fade-out) instead of a raw sin so the
///     Z's feel like they exist briefly and then vanish.
struct SleepingZs: View {
    /// Stable particle definitions — birth phase + size class. The
    /// `TimelineView` then renders each particle's current state
    /// against the global clock. Three particles staggered evenly
    /// around the unit cycle keep one always in view.
    private struct Particle {
        let birthPhase: Double  // 0..1, when this particle starts its cycle
        let fontSize: CGFloat
        let weight: Font.Weight
        let amplitude: CGFloat  // horizontal sway amplitude (px)
        let driftRight: CGFloat // net rightward drift over a cycle (px)
    }

    private let particles: [Particle] = [
        .init(birthPhase: 0.00, fontSize: 56, weight: .heavy,    amplitude: 10, driftRight: 38),
        .init(birthPhase: 0.33, fontSize: 38, weight: .bold,     amplitude:  8, driftRight: 30),
        .init(birthPhase: 0.66, fontSize: 26, weight: .semibold, amplitude:  6, driftRight: 22),
    ]

    /// One full cycle for a single Z, in seconds. Slow enough to
    /// feel restful — fast Z's read as anxious.
    private let cycleSeconds: Double = 3.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for p in particles {
                    drawParticle(ctx: &ctx, size: size, particle: p, elapsed: elapsed)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawParticle(
        ctx: inout GraphicsContext,
        size: CGSize,
        particle p: Particle,
        elapsed: TimeInterval
    ) {
        // Phase in [0, 1) for this particle right now.
        let raw = (elapsed / cycleSeconds + p.birthPhase)
        let phase = raw - floor(raw)

        // --- Easing curves --------------------------------------------------
        // Cubic-Hermite "soft pulse" for opacity: short fade-in,
        // long visible mid, short fade-out. `t * t * (3 - 2*t)`
        // is the standard smoothstep; we mirror it around 0.5.
        let pulseT = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        let smoothPulse = pulseT * pulseT * (3 - 2 * pulseT)
        let opacity = smoothPulse * 0.85

        // Eased upward rise — ease-out so motion is fastest at
        // birth and slows as the Z floats away.
        let easedRise = 1 - pow(1 - phase, 2)

        // --- Position -------------------------------------------------------
        // Origin: slightly to the upper right of the head's
        // crown. The PortraitView column is roughly square so
        // anchoring at (0.55, 0.30) puts the spawn point near the
        // top of the head where antennas would be.
        let originX = size.width  * 0.58
        let originY = size.height * 0.32

        // Rise of ~130 px over the column's height, scaled by the
        // available height so the layout adapts to window resize.
        let totalRise = min(size.height * 0.35, 160)
        let dy = -CGFloat(easedRise) * totalRise

        // Rightward drift + sinusoidal sway.
        let dx = CGFloat(easedRise) * p.driftRight
              + sin(phase * 2 * .pi) * p.amplitude

        // Subtle scale grow as the Z rises (Z's appear closer as
        // they "float up" — gentle but visible).
        let scale = 0.85 + CGFloat(easedRise) * 0.30

        // Slight off-axis rotation, easing through 0.
        let rotation = sin(phase * 2 * .pi) * 8 // ±8°

        // --- Render ---------------------------------------------------------
        // Soft glow underlayer: same Z, blurred + tinted. Sharp pass
        // crisp white on top. Colour is baked into the Text via
        // foregroundStyle BEFORE resolving (Canvas resolves once,
        // mutating shading post-resolve isn't supported on Text).
        let glowText = Text("Z")
            .font(.system(size: p.fontSize, weight: p.weight, design: .rounded))
            .italic()
            .foregroundStyle(Color(red: 0.65, green: 0.78, blue: 1.0))

        let sharpText = Text("Z")
            .font(.system(size: p.fontSize, weight: p.weight, design: .rounded))
            .italic()
            .foregroundStyle(Color.white.opacity(0.92))

        let resolvedGlow = ctx.resolve(glowText)
        let resolvedSharp = ctx.resolve(sharpText)
        let glowSize = resolvedGlow.measure(in: size)
        let sharpSize = resolvedSharp.measure(in: size)

        let centre = CGPoint(x: originX + dx, y: originY + dy)

        // Translate-rotate-scale matrix applied to a sub-context
        // so the rotation/scale composes correctly with the
        // particle's centre.
        var sub = ctx
        sub.translateBy(x: centre.x, y: centre.y)
        sub.rotate(by: .degrees(rotation))
        sub.scaleBy(x: scale, y: scale)

        // Glow pass: heavily blurred + low alpha for dreamy halo.
        var glowCtx = sub
        glowCtx.addFilter(.blur(radius: 12))
        glowCtx.opacity = opacity * 0.55
        glowCtx.draw(
            resolvedGlow,
            in: CGRect(
                x: -glowSize.width / 2,
                y: -glowSize.height / 2,
                width: glowSize.width,
                height: glowSize.height
            )
        )

        // Sharp pass.
        var sharpCtx = sub
        sharpCtx.opacity = opacity
        sharpCtx.draw(
            resolvedSharp,
            in: CGRect(
                x: -sharpSize.width / 2,
                y: -sharpSize.height / 2,
                width: sharpSize.width,
                height: sharpSize.height
            )
        )
    }
}

