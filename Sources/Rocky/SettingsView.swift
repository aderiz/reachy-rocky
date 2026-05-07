import SwiftUI

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
