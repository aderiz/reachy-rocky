import SwiftUI

/// First-run overlay — Rocky's introduction to a brand-new owner.
///
/// Per `docs/concepts/cockpit-design.md` §9, the flow is *a story, not
/// a form*. Six steps; each is a single screen with at most one or two
/// controls. The technical setup happens *as a side effect of the
/// story*: the daemon probe runs while the user reads "this is Rocky";
/// LM Studio is sniffed before the brain step asks them to pick a
/// model. The user never reads the word "sidecar."
///
/// This overlay sits on top of the cockpit window when
/// `services.settings.firstRunCompleted == false`. Pressing Esc skips
/// at any step; the flag is committed on either finish or skip. The
/// flow is restartable from `Help > Show first run`.
///
/// Step 5 (face enrolment) defers to "Maybe later" + a deep-link to
/// `Settings → Faces` in v1 — the camera-roll capture flow lives in
/// the existing `EnrollFaceForm` and isn't worth rebuilding twice.
struct FirstRunOverlay: View {
    @Environment(AppServices.self) private var services
    @State private var step: Step = .meet
    @State private var hostDraft: String = "reachy-mini.local"
    @State private var firstReplyArrived: Bool = false
    @FocusState private var hostFocused: Bool
    @FocusState private var helloFocused: Bool

    enum Step: Int, CaseIterable {
        case meet, connect, brain, hello, face, finish
        var index: Int { rawValue + 1 }
    }

    var body: some View {
        ZStack {
            // Dim the cockpit underneath without blacking it out — the
            // user should still feel Rocky is *there*.
            Rectangle()
                .fill(.black.opacity(0.55))
                .ignoresSafeArea()

            card
                .frame(maxWidth: 560)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    skipButton
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            hostDraft = services.settings.robotHost
            // Probe the world quietly while the user reads step 1.
            Task {
                await services.probeRobotPublic()
                await services.probeLMStudioPublic()
            }
        }
        .onKeyPress(.escape) {
            finish(skipped: true)
            return .handled
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepIndicator
            stepContent
                .frame(minHeight: 200, alignment: .top)
            Divider()
            footerControls
        }
        .padding(28)
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue
                          ? AnyShapeStyle(.tint)
                          : AnyShapeStyle(.tertiary))
                    .frame(width: s == step ? 32 : 16, height: 4)
                    .animation(.spring(duration: 0.35), value: step)
            }
            Spacer()
            Text("Step \(step.index) of \(Step.allCases.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .meet:    meetStep
        case .connect: connectStep
        case .brain:   brainStep
        case .hello:   helloStep
        case .face:    faceStep
        case .finish:  finishStep
        }
    }

    // MARK: - Steps

    private var meetStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meet Rocky.")
                .font(.title.weight(.semibold))
            Text("This is your desktop robot. He has a head he can turn, two antennas, eyes, ears, and a voice. The window you're looking at is where you'll work *with* him — but most of the time, you'll just talk.")
                .font(.body)
                .foregroundStyle(.primary)
            Text("He's currently \(rockyStatePhrase). Let's wire him up.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find his body.")
                .font(.title.weight(.semibold))
            Text("Rocky's brain runs on this Mac. His body — the head + antennas + speakers — runs on a tiny computer inside the robot itself, reachable over your WiFi.")
                .font(.body)
            connectStatus
            HStack {
                TextField("reachy-mini.local", text: $hostDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($hostFocused)
                    .onSubmit { applyHostDraft() }
                Button("Probe") { applyHostDraft() }
            }
            Text("Default is `reachy-mini.local`. If you set a custom hostname or IP, type it in.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var connectStatus: some View {
        switch services.daemonReachability {
        case .online:
            Label("Connected — daemon at \(services.robotEndpoint.host) is responding.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .offline(let reason):
            Label("Can't reach Rocky — \(reason).",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unknown:
            Label("Looking for Rocky on the network…",
                  systemImage: "hourglass")
                .foregroundStyle(.secondary)
        }
    }

    private var brainStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick his brain.")
                .font(.title.weight(.semibold))
            Text("Rocky uses a local LLM to talk. He works with anything that speaks the OpenAI chat protocol — LM Studio, Ollama with the OpenAI shim, llama.cpp's server, whatever you prefer.")
                .font(.body)
            brainStatus
            Text("LM Studio is the easiest path on macOS. Open it, load a model, and Rocky finds it automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open LM Studio") {
                    if let url = URL(string: "lmstudio://") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                Button("Probe again") {
                    Task { await services.probeLMStudioPublic() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var brainStatus: some View {
        switch services.llmStatus {
        case .online(let model):
            Label("Brain online — model `\(model)`.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .offline:
            Label("LM Studio not reachable — Rocky won't talk yet, but you can finish setup and start him later.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unknown:
            Label("Looking for the brain…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        }
    }

    private var helloStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Say hello.")
                .font(.title.weight(.semibold))
            Text("Try saying \u{201C}Rocky, what's your name?\u{201D} — or type something below. He'll listen for his name first, then think, then answer.")
                .font(.body)
            HStack {
                TextField("e.g. Rocky, what's your name?", text: helloDraftBinding())
                    .textFieldStyle(.roundedBorder)
                    .focused($helloFocused)
                    .onSubmit(sendHelloIfPossible)
                Button("Send") { sendHelloIfPossible() }
                    .buttonStyle(.borderedProminent)
                    .disabled(helloDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if firstReplyArrived {
                Label("He answered. You're ready.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if !services.brainTurns.isEmpty {
                Label("In flight…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @State private var helloDraft: String = ""

    private func helloDraftBinding() -> Binding<String> {
        Binding(get: { helloDraft }, set: { helloDraft = $0 })
    }

    private func sendHelloIfPossible() {
        let text = helloDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            await services.sendUserText(text)
            // Heuristic: an assistant turn arriving means we got a reply.
            // Watch for it briefly so the step's success indicator
            // updates without polling forever.
            for _ in 0..<60 {
                if let last = services.brainTurns.last,
                   last.role == "assistant",
                   !last.content.isEmpty {
                    await MainActor.run { firstReplyArrived = true }
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        helloDraft = ""
    }

    private var faceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Teach him your face.")
                .font(.title.weight(.semibold))
            Text("Rocky says hi when he recognises you. You can teach him now or later — the camera-roll enrolment lives in Settings → Faces if you'd rather pick a flattering photo.")
                .font(.body)
            HStack {
                Button {
                    // Open Settings → Faces. The standard Settings
                    // window doesn't have URL routing, so we just
                    // open it; the user clicks the Faces tab.
                    NSApp.sendAction(
                        Selector(("showSettingsWindow:")), to: nil, from: nil
                    )
                } label: {
                    Label("Open Settings → Faces", systemImage: "person.crop.rectangle.stack")
                }
                .buttonStyle(.bordered)

                Button("Maybe later") {
                    advance()
                }
                .buttonStyle(.bordered)
            }
            Text("Skip is fine — Rocky still works without recognising anyone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're set.")
                .font(.title.weight(.semibold))
            Text("Rocky's window has three places worth knowing:")
                .font(.body)
            VStack(alignment: .leading, spacing: 8) {
                tipRow(icon: "mic.fill",
                       text: "The mic toggle in the toolbar (and in the conversation strip) — Rocky listens for his name when it's on.")
                tipRow(icon: "sidebar.right",
                       text: "The inspector — open it for status, activity, motion, vision, raw events. Always one click.")
                tipRow(icon: "macwindow",
                       text: "The menu bar icon — most short interactions go through there. ⌥⌘R summons it from anywhere.")
            }
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(text)
                .font(.callout)
        }
    }

    // MARK: - Footer

    private var footerControls: some View {
        HStack {
            if step != .meet {
                Button("Back") { back() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            Button(primaryLabel) {
                advance()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(primaryDisabled)
        }
    }

    private var primaryLabel: String {
        switch step {
        case .meet:    return "Wake him up"
        case .connect: return "Continue"
        case .brain:   return "Continue"
        case .hello:   return firstReplyArrived ? "Continue" : "Skip for now"
        case .face:    return "Maybe later"
        case .finish:  return "Open the cockpit"
        }
    }

    private var primaryDisabled: Bool {
        switch step {
        case .connect:
            // Allow continuing even if offline — first-run shouldn't
            // block on hardware. Just want to show the user the
            // affordances.
            return false
        default:
            return false
        }
    }

    private var skipButton: some View {
        Button {
            finish(skipped: true)
        } label: {
            Text("Skip setup").font(.caption)
        }
        .buttonStyle(.borderless)
        .help("Close this introduction. You can revisit it from Help → Show first run.")
    }

    // MARK: - State machine

    private func back() {
        if let prev = Step(rawValue: step.rawValue - 1) {
            step = prev
        }
    }

    private func advance() {
        switch step {
        case .meet:
            // Try to wake Rocky if the daemon is online — gives an
            // immediate sense of agency.
            Task { await services.wakeRobot() }
            step = .connect
        case .connect:  step = .brain
        case .brain:    step = .hello
        case .hello:    step = .face
        case .face:     step = .finish
        case .finish:   finish(skipped: false)
        }
    }

    private func finish(skipped: Bool) {
        services.settings.firstRunCompleted = true
    }

    private func applyHostDraft() {
        let trimmed = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        services.settings.robotHost = trimmed
        Task { await services.probeRobotPublic() }
    }

    // MARK: - Helpers

    private var rockyStatePhrase: String {
        switch services.rockyState {
        case .sleeping:   return "asleep — motors disabled"
        case .waking:     return "waking up"
        case .idle:       return "awake but not paying attention yet"
        case .tracking:   return "watching"
        case .listening:  return "listening"
        case .thinking:   return "thinking"
        case .speaking:   return "speaking"
        case .error:      return "in an error state"
        }
    }
}
