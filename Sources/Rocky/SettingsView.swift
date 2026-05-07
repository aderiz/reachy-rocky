import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics
import Perception

struct SettingsView: View {
    @Environment(AppServices.self) private var services

    @State private var hostDraft: String = ""
    @State private var portDraft: String = ""
    @State private var lmURLDraft: String = ""
    @State private var lmModelDraft: String = ""
    @State private var lmApiKeyDraft: String = ""
    @State private var personaDraft: String = ""
    @State private var ttsBackendDraft: String = "say"
    @State private var micSourceDraft: String = "mac"
    @State private var savedAt: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                robotCard
                brainCard
                micCard
                ttsCard
                facesCard
                memoryCard
                personaCard
                applyBar
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 980, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { syncFromStore() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.title.weight(.semibold))
            Text("Tune Rocky's connections and personality.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Cards

    private var robotCard: some View {
        Card {
            CardHeader("Robot", icon: "antenna.radiowaves.left.and.right")
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                field(label: "Host", placeholder: "reachy-mini.local", text: $hostDraft)
                field(label: "Port", placeholder: "8000", text: $portDraft, width: 96)
                Text("Endpoint changes take effect on relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var brainCard: some View {
        Card {
            CardHeader("Brain (LM Studio)", icon: "brain") {
                Button {
                    Task { await services.probeLMStudioPublic() }
                } label: {
                    Label("Re-probe", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                field(label: "Base URL",
                      placeholder: "http://localhost:1234/v1",
                      text: $lmURLDraft, width: 360)
                modelRow
                field(label: "API key", placeholder: "(blank for none)",
                      text: $lmApiKeyDraft, isSecure: true, width: 280)
                Text("Apply hot-reloads the client and refreshes the model list. No relaunch needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelRow: some View {
        let models = services.availableLLMModels
        return HStack(alignment: .firstTextBaseline) {
            Text("Model")
                .font(.callout.weight(.medium))
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
            if models.isEmpty {
                TextField("(LM Studio offline)", text: $lmModelDraft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(width: 280)
                    .background(textFieldBackground)
            } else {
                Picker("", selection: $lmModelDraft) {
                    // Always include a tag matching the current draft so
                    // `selection` is never "" / unmatched (which makes
                    // SwiftUI log "selection is invalid…"). Covers two
                    // cases: the draft is briefly empty before
                    // `syncFromStore` runs, and the saved model isn't
                    // currently loaded in LM Studio.
                    if !models.contains(lmModelDraft) {
                        Text(lmModelDraft.isEmpty
                             ? "—"
                             : "\(lmModelDraft) (not loaded)")
                            .tag(lmModelDraft)
                    }
                    ForEach(models, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)
            }
        }
    }

    private var micCard: some View {
        Card {
            CardHeader("Microphone", icon: "mic")
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Source", selection: $micSourceDraft) {
                    Text("Robot mic (Reachy 4-mic array)").tag("robot")
                    Text("Mac mic (built-in / system default)").tag("mac")
                }
                .pickerStyle(.radioGroup)
                Text("Robot mic uses Reachy's 4-mic ReSpeaker array via WebRTC. Run \u{201C}./Sidecars/robot-mic/setup.sh\u{201D} once. Source change takes effect on the next Listen toggle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var ttsCard: some View {
        Card {
            CardHeader("Voice (TTS)", icon: "speaker.wave.2")
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Engine", selection: $ttsBackendDraft) {
                    Text("System voice (say)").tag("say")
                    Text("Chatterbox FP16 (cloned)").tag("chatterbox")
                }
                .pickerStyle(.radioGroup)
                Text("Chatterbox uses your cloned voice from ~/Library/Application Support/Rocky/voice/. Engine change takes effect on next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                BotVolumeSlider()
            }
        }
    }

    private var facesCard: some View {
        // Snapshot is read once per body eval. Down-stream EnrolledFacesList
        // doesn't read services at all, so its identity (and the form's)
        // stays stable across services-driven re-renders.
        let people = services.enrolledPeople
        return Card {
            CardHeader("Known Faces", icon: "person.crop.rectangle.stack") {
                if !people.isEmpty {
                    Text("\(people.count) enrolled")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rocky says \u{201C}hey\u{201D} when he recognises someone. Add a name, an optional phonetic spelling for TTS, and one or more photos (or grab the current camera frame).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                EnrollFaceForm()

                FaceMatchThresholdSlider()

                if !people.isEmpty {
                    Divider().padding(.vertical, 4)
                    EnrolledFacesList(people: people)
                }
            }
        }
    }

    private var memoryCard: some View {
        Card {
            CardHeader("Memory", icon: "brain") {
                if services.memoryDrawerCount >= 0 {
                    Text("\(services.memoryDrawerCount) drawer\(services.memoryDrawerCount == 1 ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rocky stores every user and assistant utterance verbatim, then pulls the most relevant snippets into the next reply. Storage is local — see ~/Library/Application Support/Rocky/Memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                MemoryStatusLine()

                MemoryRecallToggle()

                MemoryTopKSlider()

                MemoryForgetButton()
            }
        }
    }

    private var personaCard: some View {
        Card {
            CardHeader("Persona", icon: "text.quote") {
                Button("Reset") {
                    personaDraft = SettingsStore.defaultPersona
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $personaDraft)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 200)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.gray.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.gray.opacity(0.18), lineWidth: 1)
                    )
                Text("System prompt. Edit to change Rocky's voice and rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var applyBar: some View {
        HStack {
            if let savedAt {
                Label("Saved \(savedAt.formatted(.dateTime.hour().minute().second()))",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("Apply") {
                Task { await apply() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isDirty)
        }
        .padding(.top, 6)
    }

    // MARK: - Field helper

    @ViewBuilder
    private func field(
        label: String,
        placeholder: String,
        text: Binding<String>,
        isSecure: Bool = false,
        width: CGFloat = 280
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout.weight(.medium))
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(width: width)
            .background(textFieldBackground)
        }
    }

    private var textFieldBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.gray.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.gray.opacity(0.20), lineWidth: 1)
            )
    }

    // MARK: - Apply / sync

    private var isDirty: Bool {
        hostDraft != services.settings.robotHost
            || portDraft != String(services.settings.robotPort)
            || lmURLDraft != services.settings.lmStudioURL
            || lmModelDraft != services.settings.lmStudioModel
            || lmApiKeyDraft != services.settings.lmStudioApiKey
            || personaDraft != services.settings.persona
            || ttsBackendDraft != services.settings.ttsBackend
            || micSourceDraft != services.settings.micSource
    }

    private func syncFromStore() {
        hostDraft = services.settings.robotHost
        portDraft = String(services.settings.robotPort)
        lmURLDraft = services.settings.lmStudioURL
        lmModelDraft = services.settings.lmStudioModel
        lmApiKeyDraft = services.settings.lmStudioApiKey
        personaDraft = services.settings.persona
        ttsBackendDraft = services.settings.ttsBackend
        micSourceDraft = services.settings.micSource
    }

    private func apply() async {
        let store = services.settings
        store.robotHost = hostDraft.trimmingCharacters(in: .whitespaces)
        if let p = Int(portDraft.trimmingCharacters(in: .whitespaces)) {
            store.robotPort = p
        }
        store.lmStudioURL = lmURLDraft.trimmingCharacters(in: .whitespaces)
        store.lmStudioModel = lmModelDraft.trimmingCharacters(in: .whitespaces)
        store.lmStudioApiKey = lmApiKeyDraft
        store.persona = personaDraft
        store.ttsBackend = ttsBackendDraft
        store.micSource = micSourceDraft
        await services.applySettings()
        savedAt = Date()
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
