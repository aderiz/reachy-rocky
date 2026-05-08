import SwiftUI
import AppKit
import AVFoundation
import CoreLocation
import EventKit
import Speech
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics
import Perception

/// Macroscopic shell for the macOS Settings scene. Per
/// `docs/concepts/cockpit-design.md` §7, settings live in a separate
/// window with six tabs (Robot, Brain, Voice, Memory, Faces, Persona).
/// Apply-on-commit per field where safe; the robot endpoint is the
/// sole exception (relaunch-required, so it stages with a dedicated
/// Apply button).
///
/// Each tab body uses `Form` for native macOS spacing and label
/// alignment. The tabs all share the surrounding `TabView`'s padding
/// and the same minimum width so switching tabs doesn't reflow the
/// window.
struct SettingsView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        TabView {
            RobotSettingsTab()
                .tabItem { Label("Robot", systemImage: "antenna.radiowaves.left.and.right") }
            BrainSettingsTab()
                .tabItem { Label("Brain", systemImage: "brain") }
            VoiceSettingsTab()
                .tabItem { Label("Voice", systemImage: "speaker.wave.2") }
            MemorySettingsTab()
                .tabItem { Label("Memory", systemImage: "tray.full") }
            FacesSettingsTab()
                .tabItem { Label("Faces", systemImage: "person.crop.rectangle.stack") }
            PersonaSettingsTab()
                .tabItem { Label("Persona", systemImage: "text.quote") }
            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "checkmark.shield") }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 460)
    }
}

// MARK: - Robot tab

/// Robot endpoint. Host + port require a relaunch (URLSession sockets
/// + sidecars hold the original endpoint), so we keep a draft + Apply
/// here. The tab also surfaces the daemon status with a probe-now
/// button so the user can verify connectivity without leaving the
/// window.
private struct RobotSettingsTab: View {
    @Environment(AppServices.self) private var services
    @State private var hostDraft: String = ""
    @State private var portDraft: String = ""

    var body: some View {
        Form {
            Section {
                TextField("Host", text: $hostDraft, prompt: Text("reachy-mini.local"))
                TextField("Port", text: $portDraft, prompt: Text("8000"))
                    .frame(maxWidth: 120)
            } header: {
                Text("Robot endpoint")
            } footer: {
                Text("Endpoint changes take effect at next launch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("Daemon") { reachabilityLabel }
                LabeledContent("Probe") {
                    Button {
                        Task { await services.probeRobotPublic() }
                    } label: {
                        Label("Probe now", systemImage: "arrow.clockwise")
                    }
                }
            }

            Section("Storage") {
                LabeledContent("Application support") {
                    Text("~/Library/Application Support/Rocky/")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            applyRow
        }
        .formStyle(.grouped)
        .onAppear {
            hostDraft = services.settings.robotHost
            portDraft = String(services.settings.robotPort)
        }
    }

    @ViewBuilder
    private var reachabilityLabel: some View {
        switch services.daemonReachability {
        case .online:
            Label("Online", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .offline(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .unknown:
            Label("Checking…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        }
    }

    private var dirty: Bool {
        hostDraft.trimmingCharacters(in: .whitespaces) != services.settings.robotHost
            || portDraft != String(services.settings.robotPort)
    }

    @ViewBuilder
    private var applyRow: some View {
        if dirty {
            HStack {
                Spacer()
                Text("Will apply at next launch.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("Apply") {
                    services.settings.robotHost =
                        hostDraft.trimmingCharacters(in: .whitespaces)
                    if let p = Int(portDraft.trimmingCharacters(in: .whitespaces)) {
                        services.settings.robotPort = p
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Brain tab

/// LLM endpoint. Hot-reloads on edit via `applySettings()` — no Apply
/// button, no relaunch. The model picker is sourced live from LM
/// Studio's `/v1/models` so changing models is one click.
private struct BrainSettingsTab: View {
    @Environment(AppServices.self) private var services
    @State private var lmURLDraft: String = ""
    @State private var lmApiKeyDraft: String = ""
    @State private var braveKeyDraft: String = ""

    var body: some View {
        Form {
            Section {
                TextField("Base URL", text: $lmURLDraft,
                          prompt: Text("http://localhost:1234/v1"))
                    .onSubmit { commitURL() }
                modelPicker
                SecureField("API key", text: $lmApiKeyDraft,
                            prompt: Text("(blank for none)"))
                    .onSubmit { commitAPIKey() }
            } header: {
                Text("LM Studio")
            } footer: {
                Text("Submitted fields hot-reload the cognition engine. No relaunch needed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Brave Search API key", text: $braveKeyDraft,
                            prompt: Text("paste from search.brave.com/api"))
                    .onSubmit { commitBraveKey() }
            } header: {
                Text("Web search")
            } footer: {
                Text("Used by the `search_web` tool. Free tier allows 1 query/sec; leave blank to disable web search.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("Brain") { llmLabel }
                LabeledContent("Re-probe") {
                    Button {
                        Task { await services.probeLMStudioPublic() }
                    } label: {
                        Label("Probe", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            lmURLDraft = services.settings.lmStudioURL
            lmApiKeyDraft = services.settings.lmStudioApiKey
            braveKeyDraft = services.settings.braveSearchAPIKey
        }
    }

    private func commitBraveKey() {
        guard braveKeyDraft != services.settings.braveSearchAPIKey else { return }
        services.settings.braveSearchAPIKey = braveKeyDraft
    }

    private var modelPicker: some View {
        let models = services.availableLLMModels
        let store = services.settings
        return Picker("Model", selection: Binding(
            get: { store.lmStudioModel },
            set: { newValue in
                store.lmStudioModel = newValue
                Task { await services.applySettings() }
            }
        )) {
            // Stable tag for the current value even when not in the list
            // — prevents "selection invalid" warnings when LM Studio is
            // offline or the model isn't loaded.
            if !models.contains(store.lmStudioModel) {
                Text(store.lmStudioModel.isEmpty
                     ? "—"
                     : "\(store.lmStudioModel) (not loaded)")
                    .tag(store.lmStudioModel)
            }
            ForEach(models, id: \.self) { m in
                Text(m).tag(m)
            }
        }
    }

    @ViewBuilder
    private var llmLabel: some View {
        switch services.llmStatus {
        case .online(let model):
            Label(model, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(1)
        case .offline(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .unknown:
            Label("Checking…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        }
    }

    private func commitURL() {
        let trimmed = lmURLDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed != services.settings.lmStudioURL else { return }
        services.settings.lmStudioURL = trimmed
        Task { await services.applySettings() }
    }

    private func commitAPIKey() {
        guard lmApiKeyDraft != services.settings.lmStudioApiKey else { return }
        services.settings.lmStudioApiKey = lmApiKeyDraft
        Task { await services.applySettings() }
    }
}

// MARK: - Voice tab

/// Microphone source + TTS engine + speaker volume. Source / engine
/// changes are saved instantly but only take effect on the next listen
/// toggle / next launch (the underlying sidecars hold the original
/// configuration); the volume slider applies live via PCM scaling
/// during synthesis.
private struct VoiceSettingsTab: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Form {
            Section {
                Picker("Source", selection: micSourceBinding) {
                    Text("Robot mic (Reachy 4-mic array)").tag("robot")
                    Text("Mac mic (built-in / system)").tag("mac")
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Robot mic uses Reachy's 4-mic ReSpeaker array via WebRTC. " +
                     "Run ./Sidecars/robot-mic/setup.sh once. Source change " +
                     "applies on the next Listen toggle.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Engine", selection: ttsBackendBinding) {
                    Text("System voice (say)").tag("say")
                    Text("Chatterbox FP16 (cloned)").tag("chatterbox")
                }
                BotVolumeSlider()
            } header: {
                Text("Voice (TTS)")
            } footer: {
                Text("Chatterbox uses your cloned voice from " +
                     "~/Library/Application Support/Rocky/voice/. " +
                     "Engine change applies on next launch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var micSourceBinding: Binding<String> {
        let store = services.settings
        return Binding(get: { store.micSource },
                       set: { store.micSource = $0 })
    }

    private var ttsBackendBinding: Binding<String> {
        let store = services.settings
        return Binding(get: { store.ttsBackend },
                       set: { store.ttsBackend = $0 })
    }
}

// MARK: - Memory tab

/// Memory recall toggle + top-K slider + drawer count + forget. All
/// existing controls re-homed from the old long-scroll into a focused
/// tab. Each control already commits-on-change.
private struct MemorySettingsTab: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Form {
            Section {
                MemoryStatusLine()
                MemoryRecallToggle()
                MemoryTopKSlider()
            } header: {
                Text("Recall")
            } footer: {
                Text("Rocky stores every user and assistant utterance verbatim, " +
                     "then pulls the most relevant snippets into the next reply. " +
                     "Storage is local — see ~/Library/Application Support/Rocky/Memory.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Manage") {
                MemoryForgetButton()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Faces tab

/// Enrolment + threshold + the list of known people.
private struct FacesSettingsTab: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        // Snapshot once per body eval — EnrolledFacesList doesn't read
        // services, so its identity stays stable across services-driven
        // re-renders.
        let people = services.enrolledPeople
        return Form {
            Section {
                EnrollFaceForm()
            } header: {
                Text("Add a face")
            } footer: {
                Text("Rocky says \u{201C}hey\u{201D} when he recognises someone. " +
                     "Add a name, an optional phonetic spelling for TTS, and one " +
                     "or more photos.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Match threshold") {
                FaceMatchThresholdSlider()
            }

            if !people.isEmpty {
                Section("Enrolled (\(people.count))") {
                    EnrolledFacesList(people: people)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Persona tab

/// Full-width, full-height TextEditor for Rocky's system prompt. Hot-
/// reloads on edit (debounced — saves every time the user pauses for
/// 1 s) so the next turn picks up the new persona without an Apply
/// button.
private struct PersonaSettingsTab: View {
    @Environment(AppServices.self) private var services
    @State private var draft: String = ""
    @State private var savedAt: Date?
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Persona")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Reset to default") {
                    draft = SettingsStore.defaultPersona
                    commit()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Text("System prompt the LLM sees on every turn. Edits hot-reload — " +
                 "the next turn uses the new persona. Auto-saves on pause.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $draft)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: draft) { _, _ in scheduleCommit() }

            HStack {
                Text("\(draft.count) characters")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let savedAt {
                    Label("Saved \(savedAt.formatted(.dateTime.hour().minute().second()))",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.horizontal, 4)
        .onAppear { draft = services.settings.persona }
    }

    private func scheduleCommit() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            commit()
        }
    }

    private func commit() {
        guard draft != services.settings.persona else { return }
        services.settings.persona = draft
        Task {
            await services.applySettings()
            await MainActor.run { savedAt = Date() }
        }
    }
}

/// Self-contained enrollment form. Owns its own `@State` for the form
/// fields and never reads any `services.*` property in its body, so
/// services-driven UI mutations elsewhere (camera frames, robot state,
/// face detections) cannot invalidate it and steal TextField focus.
private struct EnrollFaceForm: View {
    @Environment(AppServices.self) private var services

    @State private var name: String = ""
    @State private var pronunciation: String = ""
    @State private var photos: [Data] = []
    @State private var error: String?
    @State private var submitting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Name", placeholder: "Alice", text: $name)
            row("Says",
                placeholder: "phonetic spelling (optional, e.g. shi-vawn)",
                text: $pronunciation, width: 360)

            HStack(spacing: 8) {
                Button {
                    choosePhotos()
                } label: {
                    Label("Choose photos\u{2026}",
                          systemImage: "photo.on.rectangle.angled")
                }
                Button {
                    useCameraFrame()
                } label: {
                    Label("Use current frame", systemImage: "camera")
                }
                Spacer()
            }

            if !photos.isEmpty { photoStrip }

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button {
                    Task { await submit() }
                } label: {
                    if submitting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Adding\u{2026}")
                        }
                    } else {
                        Label("Add face", systemImage: "person.fill.badge.plus")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    submitting
                    || name.trimmingCharacters(in: .whitespaces).isEmpty
                    || photos.isEmpty
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.gray.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.gray.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Subviews

    @ViewBuilder
    private func row(_ label: String,
                     placeholder: String,
                     text: Binding<String>,
                     width: CGFloat = 280) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout.weight(.medium))
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(width: width)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.gray.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.gray.opacity(0.20), lineWidth: 1)
                )
        }
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(photos.enumerated()), id: \.offset) { idx, data in
                    ZStack(alignment: .topTrailing) {
                        if let img = NSImage(data: data) {
                            Image(nsImage: img)
                                .resizable()
                                .interpolation(.medium)
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.gray.opacity(0.2))
                                .frame(width: 64, height: 64)
                        }
                        Button {
                            photos.remove(at: idx)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .background(Circle().fill(.black.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .padding(3)
                    }
                }
            }
        }
        .frame(height: 72)
    }

    // MARK: - Actions (run on Button taps; do not register SwiftUI deps)

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .jpeg, .png, .heic]
        panel.message = "Choose one or more photos that clearly show the face."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let data = Self.loadImageAsJPEG(url: url) {
                photos.append(data)
            }
        }
    }

    private func useCameraFrame() {
        guard let frame = services.lastCameraFrame else {
            error = "No camera frame available yet — wait for the Vision card to show one."
            return
        }
        photos.append(frame.jpeg)
        error = nil
    }

    private func submit() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !photos.isEmpty else { return }
        submitting = true
        error = nil
        let success = await services.enrollFace(
            name: trimmed, pronunciation: pronunciation, photoJPEGs: photos
        )
        submitting = false
        if success {
            name = ""
            pronunciation = ""
            photos = []
        } else {
            error = "No face detected in those photos. Try a clearer shot or a different angle."
        }
    }

    private static func loadImageAsJPEG(url: URL) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }
}

/// Robot speaker output volume. Drags apply live by scaling the next
/// synthesized WAV's PCM samples — no daemon round-trip needed. The
/// underlying setting persists immediately.
private struct BotVolumeSlider: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let value = services.settings.audioVolume
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Robot speaker volume")
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
            }
            Slider(
                value: Binding(
                    get: { services.settings.audioVolume },
                    set: { newValue in
                        services.settings.audioVolume = newValue
                        Task { await services.robotTTS.setVolume(newValue) }
                    }
                ),
                in: 0.0...1.0,
                step: 0.05
            ) {
                Text("Volume")
            } minimumValueLabel: {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Applied to every TTS clip before it's uploaded to the robot — works for both Chatterbox cloned voice and the system fallback.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Match-threshold slider with a live distance readout. Drags apply
/// instantly to `services.faceLibrary` so the user can tune by watching
/// the live bbox label in the Vision card flip from `?` to the name.
private struct FaceMatchThresholdSlider: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let threshold = services.settings.faceMatchThreshold
        let live = services.lastFaceDetection?.closestDistance
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Match threshold")
                Spacer()
                Text(String(format: "%.2f", threshold))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                if let liveD = live {
                    Text(String(format: "live %.2f", liveD))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(liveD <= threshold ? .green : .secondary)
                }
            }
            Slider(
                value: Binding(
                    get: { services.settings.faceMatchThreshold },
                    set: { newValue in
                        services.settings.faceMatchThreshold = newValue
                        Task { await services.faceLibrary.setAcceptThreshold(newValue) }
                    }
                ),
                in: 0.4...1.5,
                step: 0.05
            ) {
                Text("Threshold")
            } minimumValueLabel: {
                Text("strict").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("loose").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Lower = stricter; only very close matches accepted. Watch the \u{201C}live\u{201D} number while a face is on camera — set the threshold a touch higher than the distance you see for known people. Default 1.0.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Reads `services.*` only inside the row's onRemove / onTogglePrimary
/// closures, never in body — so the list itself doesn't churn with services.
private struct EnrolledFacesList: View {
    @Environment(AppServices.self) private var services
    let people: [FaceLibrary.Person]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(people) { person in
                FaceRow(
                    person: person,
                    onTogglePrimary: {
                        let target: UUID? = person.isPrimary ? nil : person.id
                        Task { await services.setPrimaryFace(id: target) }
                    },
                    onRemove: {
                        let id = person.id
                        Task { await services.removeFace(id: id) }
                    }
                )
            }
            Text("The starred face is the only one Rocky's head will track. Other recognised faces still get greeted when they come into view, but the head stays on the primary.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
}

private struct FaceRow: View {
    let person: FaceLibrary.Person
    let onTogglePrimary: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(person.name)
                        .font(.callout.weight(.medium))
                    if person.isPrimary {
                        Text("primary")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
                if !person.pronunciation.isEmpty {
                    Text("says \u{201C}\(person.pronunciation)\u{201D}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(person.samplesB64.count) sample\(person.samplesB64.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                onTogglePrimary()
            } label: {
                Image(systemName: person.isPrimary ? "star.fill" : "star")
                    .foregroundStyle(person.isPrimary ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(person.isPrimary
                  ? "Clear primary — Rocky will fall back to tracking the largest face."
                  : "Make \(person.name) the primary — Rocky will only track this face.")
            Button {
                onRemove()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove \(person.name) from the face library")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.gray.opacity(0.04))
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let firstSample = person.sampleData.first,
           let img = NSImage(data: firstSample) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.gray.opacity(0.2))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                )
        }
    }
}

// MARK: - Memory subviews

/// Read-only summary of the memory sidecar's state + drawer count.
private struct MemoryStatusLine: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let detail = stateDetail()
        HStack(spacing: 8) {
            Image(systemName: detail.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(detail.tint)
            Text(detail.text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await services.refreshMemoryCount() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Re-poll the sidecar for the current drawer count.")
        }
    }

    private func stateDetail() -> (icon: String, tint: Color, text: String) {
        switch services.memorySidecarState {
        case .stopped:
            return ("xmark.circle.fill", .gray,
                    "stopped — run Sidecars/mempalace/setup.sh")
        case .starting:
            return ("hourglass", .orange, "starting…")
        case .ready:
            let n = services.memoryDrawerCount
            let countText = n < 0
                ? "drawer count pending"
                : (n == 1 ? "1 drawer stored" : "\(n) drawers stored")
            return ("checkmark.circle.fill", .green, "online · " + countText)
        case .failing(let reason):
            return ("exclamationmark.triangle.fill", .red, "failing — " + reason)
        case .circuitOpen(let until):
            let s = max(0, Int(until.timeIntervalSinceNow))
            return ("exclamationmark.triangle.fill", .red, "cooldown · \(s)s")
        }
    }
}

/// "Recall prior conversations" toggle. When off, post-turn writes
/// still happen so a future re-enable has full history; only the
/// pre-turn recall step is skipped.
private struct MemoryRecallToggle: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Toggle(isOn: Binding(
            get: { services.settings.memoryRecallEnabled },
            set: { newValue in
                services.settings.memoryRecallEnabled = newValue
                Task { await services.applySettings() }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recall prior conversations").font(.callout.weight(.medium))
                Text("Inject the top-K most relevant snippets into each LLM turn. Writes always happen regardless.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}

/// Top-K slider — how many drawers to pull per recall.
private struct MemoryTopKSlider: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let value = services.settings.memoryTopK
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Snippets per recall (top-K)")
                Spacer()
                Text("\(value)")
                    .font(.caption.monospacedDigit().weight(.medium))
            }
            Slider(
                value: Binding(
                    get: { Double(services.settings.memoryTopK) },
                    set: { newValue in
                        let clamped = max(1, min(10, Int(newValue.rounded())))
                        if clamped != services.settings.memoryTopK {
                            services.settings.memoryTopK = clamped
                            Task { await services.applySettings() }
                        }
                    }
                ),
                in: 1...10,
                step: 1
            ) {
                Text("Top-K")
            } minimumValueLabel: {
                Text("1").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("10").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Lower keeps the prompt focused; higher gives more context at the cost of tokens and noise.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .disabled(!services.settings.memoryRecallEnabled)
        .opacity(services.settings.memoryRecallEnabled ? 1 : 0.45)
        .padding(.vertical, 4)
    }
}

/// Destructive "Forget everything" button. Confirms before wiping every
/// drawer in Rocky's wing/room. Disabled when memory is offline or empty.
private struct MemoryForgetButton: View {
    @Environment(AppServices.self) private var services
    @State private var confirming: Bool = false
    @State private var working: Bool = false
    @State private var lastResult: String?

    var body: some View {
        let isReady = services.memorySidecarState == .ready
        let isEmpty = services.memoryDrawerCount == 0
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(role: .destructive) {
                    confirming = true
                } label: {
                    Label("Forget everything", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(working || !isReady || isEmpty)

                if working {
                    ProgressView().controlSize(.small)
                }
                if let lastResult {
                    Text(lastResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Removes every stored drawer for the rocky / conversation room. Cannot be undone.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .alert("Forget every memory?",
               isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Forget everything", role: .destructive) {
                working = true
                Task {
                    let n = await services.forgetAllMemory()
                    await MainActor.run {
                        working = false
                        lastResult = "deleted \(n)"
                    }
                }
            }
        } message: {
            Text("This deletes every stored drawer in Rocky's palace. He won't remember any prior conversations after this.")
        }
    }
}

// MARK: - Permissions tab

/// Live view of the four TCC permissions Rocky uses, mirroring the
/// first-run "Grant access" step. Useful when a permission gets
/// revoked, when the user wants to re-prompt for one that was
/// denied, or just to confirm what's been granted. Status refreshes
/// on every render and on `NSApplication.didBecomeActive` (when the
/// user comes back from System Settings).
private struct PermissionsSettingsTab: View {
    @Environment(AppServices.self) private var services
    @State private var refreshTick = 0

    var body: some View {
        Form {
            Section {
                if services.settings.micSource != "robot" {
                    permissionRow(
                        icon: "mic.fill",
                        title: "Microphone",
                        rationale: "So Rocky can hear you say his name.",
                        status: micStatus,
                        anchor: "Privacy_Microphone",
                        grant: { _ = await AVCaptureDevice.requestAccess(for: .audio) }
                    )
                }
                permissionRow(
                    icon: "waveform",
                    title: "Speech recognition",
                    rationale: "So your words become text Rocky can act on.",
                    status: speechStatus,
                    anchor: "Privacy_SpeechRecognition",
                    grant: { _ = await services.appleSTT.requestAuthorization() }
                )
                permissionRow(
                    icon: "calendar",
                    title: "Calendar",
                    rationale: "So Rocky can answer \"what's on tomorrow?\" without guessing.",
                    status: calendarStatus,
                    anchor: "Privacy_Calendars",
                    grant: {
                        let store = EKEventStore()
                        _ = try? await store.requestFullAccessToEvents()
                    }
                )
                permissionRow(
                    icon: "location.fill",
                    title: "Location",
                    rationale: "So \"what's the weather?\" works without naming the city.",
                    status: locationStatus,
                    anchor: "Privacy_LocationServices",
                    grant: { _ = await LocationProvider.shared.requestAuthorization() }
                )
            } header: {
                Text("System permissions")
            } footer: {
                Text("macOS shows the prompt the first time Rocky needs each permission. After that, denied entries can only be re-enabled in System Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .id(refreshTick)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            // Trigger a re-render so the row reads fresh TCC state
            // when the user returns from System Settings.
            refreshTick &+= 1
        }
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: String,
        rationale: String,
        status: PermissionRowStatus,
        anchor: String,
        grant: @escaping @Sendable () async -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(rationale).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption.weight(.medium))
            case .denied:
                HStack(spacing: 6) {
                    Label("Denied", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption.weight(.medium))
                    Button("Open Settings") {
                        let url = URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
                        )!
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            case .unknown:
                Button("Grant") { Task { await grant() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Status readers

    private enum PermissionRowStatus { case granted, denied, unknown }

    private var micStatus: PermissionRowStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:                 return .granted
        case .denied, .restricted:        return .denied
        case .notDetermined:              return .unknown
        @unknown default:                 return .unknown
        }
    }

    private var speechStatus: PermissionRowStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:                 return .granted
        case .denied, .restricted:        return .denied
        case .notDetermined:              return .unknown
        @unknown default:                 return .unknown
        }
    }

    private var calendarStatus: PermissionRowStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:    return .granted
        case .denied, .restricted, .writeOnly: return .denied
        case .notDetermined:              return .unknown
        @unknown default:                 return .unknown
        }
    }

    private var locationStatus: PermissionRowStatus {
        // Inverted check matches `LocationProvider.currentLocation()` —
        // anything that isn't explicitly bad reads as granted.
        switch LocationProvider.shared.authorizationStatus {
        case .denied, .restricted: return .denied
        case .notDetermined:       return .unknown
        default:                   return .granted
        }
    }
}
