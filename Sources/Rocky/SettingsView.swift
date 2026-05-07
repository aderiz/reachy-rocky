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
                .font(.system(size: 28, weight: .bold, design: .rounded))
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
                    if !models.contains(lmModelDraft) && !lmModelDraft.isEmpty {
                        Text("\(lmModelDraft) (not loaded)").tag(lmModelDraft)
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
            VStack(alignment: .leading, spacing: 10) {
                Picker("Engine", selection: $ttsBackendDraft) {
                    Text("System voice (say)").tag("say")
                    Text("Chatterbox FP16 (cloned)").tag("chatterbox")
                }
                .pickerStyle(.radioGroup)
                Text("Chatterbox uses your cloned voice from ~/Library/Application Support/Rocky/voice/. Engine change takes effect on next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                if !people.isEmpty {
                    Divider().padding(.vertical, 4)
                    EnrolledFacesList(people: people)
                }
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

/// Reads `services.removeFace` only inside the row's onRemove closure,
/// never in body — so the list itself doesn't churn with services.
private struct EnrolledFacesList: View {
    @Environment(AppServices.self) private var services
    let people: [FaceLibrary.Person]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(people) { person in
                FaceRow(person: person) {
                    let id = person.id
                    Task { await services.removeFace(id: id) }
                }
            }
        }
    }
}

private struct FaceRow: View {
    let person: FaceLibrary.Person
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.callout.weight(.medium))
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
