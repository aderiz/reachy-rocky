import SwiftUI

/// Shown on every cold launch while the app waits to reach the
/// Reachy Mini's daemon (or relay) the first time.
///
/// Why a dedicated overlay rather than the existing per-row health
/// indicator: the user's complaint was that opening Rocky without
/// the bot powered on produced a silent ~5–15 s window where the
/// UI looked unresponsive — no spinner, no message, no signal that
/// the app was *trying*. The overlay sits over the cockpit during
/// that window with an animated "searching" indicator and the
/// resolved hostname so the user knows we're attempting to find
/// the bot.
///
/// Dismissal: auto when `daemonReachability == .online`. Manual via
/// the "Use offline" button, which stashes `botConnectingDismissed`
/// for this app run so the overlay doesn't re-appear on every probe
/// retry. The dismiss flag resets when the app process restarts —
/// next launch tries again, but the user can still bail.
///
/// First-run takes precedence: this overlay only shows when
/// `firstRunCompleted == true`. During first-run the dedicated
/// `connect` step in `FirstRunOverlay` already handles the
/// reachability message.
struct BotConnectingOverlay: View {
    @Environment(AppServices.self) private var services
    @State private var dismissed: Bool = false
    @State private var elapsed: TimeInterval = 0
    @State private var pulse: Bool = false
    @State private var sweep: Double = 0
    private let appearedAt = Date()

    var body: some View {
        // Session-sticky dismissal: once the user clicks "Use
        // offline" we don't reappear even if the daemon goes
        // offline→online→offline. RootView gates the *initial*
        // appearance (reachability != .online); this `if` gates
        // re-appearance after a manual dismiss.
        if dismissed {
            Color.clear
        } else {
            modal
        }
    }

    private var modal: some View {
        ZStack {
            // Backdrop. Lighter than FirstRunOverlay's heavy dim so
            // the cockpit shows through — connection state is a
            // transient gate, not an onboarding moment.
            Rectangle()
                .fill(.black.opacity(0.45))
                .ignoresSafeArea()

            VStack(spacing: 22) {
                radarAnimation
                    .frame(width: 140, height: 140)

                VStack(spacing: 8) {
                    Text(headline)
                        .font(.title2.weight(.semibold))
                    Text(subhead)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                if case .offline(let reason) = services.daemonReachability,
                   elapsed > 3 {
                    Text(reason)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: 320)
                        .transition(.opacity)
                }

                HStack(spacing: 12) {
                    Button("Retry now") {
                        Task { await services.probeRobotPublic() }
                    }
                    .controlSize(.large)
                    Button("Use offline") {
                        withAnimation(.easeOut(duration: 0.2)) {
                            dismissed = true
                        }
                    }
                    .controlSize(.large)
                }
                .buttonStyle(.borderedProminent)
                .opacity(elapsed > 1.0 ? 1 : 0)
                .animation(.easeIn(duration: 0.3), value: elapsed > 1.0)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
            )
            .frame(maxWidth: 420)
        }
        .onAppear { startAnimations() }
        .task {
            // Keep `elapsed` ticking so the "Retry / Use offline"
            // controls can fade in after a moment, and the offline
            // reason can surface after 3 s of failed probes.
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(appearedAt)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    // MARK: - Copy

    private var headline: String {
        switch services.daemonReachability {
        case .online: return "Connected"
        case .unknown: return "Looking for Rocky…"
        case .offline: return elapsed > 4 ? "Can't reach Rocky" : "Looking for Rocky…"
        }
    }

    private var subhead: String {
        let host = "\(services.settings.robotHost):\(services.settings.robotPort)"
        switch services.daemonReachability {
        case .online:
            return "Daemon online at \(host)."
        case .unknown:
            return "Trying \(host)…"
        case .offline:
            if elapsed > 4 {
                return "Make sure the robot is powered on and on the same WiFi. Rocky will reconnect automatically when it appears."
            }
            return "Trying \(host)…"
        }
    }

    // MARK: - Radar animation
    //
    // Two-layer concentric pulse + a slow sweeping arc. Reads as
    // "scanning" without being noisy. The pulse is the dominant
    // signal — the sweep is decoration so a static frame still
    // communicates motion.

    private var radarAnimation: some View {
        ZStack {
            // Outer pulsing ring — expands + fades.
            Circle()
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 2)
                .scaleEffect(pulse ? 1.0 : 0.4)
                .opacity(pulse ? 0.0 : 0.9)

            // Middle pulsing ring, offset phase.
            Circle()
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)
                .scaleEffect(pulse ? 0.7 : 0.3)
                .opacity(pulse ? 0.2 : 1.0)

            // Static centre dot — Rocky.
            Circle()
                .fill(Color.accentColor)
                .frame(width: 14, height: 14)
                .shadow(color: .accentColor.opacity(0.6), radius: 6)

            // Sweeping arc — slow rotation.
            Circle()
                .trim(from: 0, to: 0.18)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0),
                            Color.accentColor.opacity(0.85),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(sweep))
        }
    }

    private func startAnimations() {
        withAnimation(
            .easeInOut(duration: 1.6).repeatForever(autoreverses: false)
        ) {
            pulse = true
        }
        withAnimation(
            .linear(duration: 2.4).repeatForever(autoreverses: false)
        ) {
            sweep = 360
        }
    }
}
