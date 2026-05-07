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

                section(title: "Robot",
                        footer: "Endpoint changes take effect on relaunch.") {
                    LabeledContent("Host") {
                        TextField("reachy-mini.local", text: $hostDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                    }
                    LabeledContent("Port") {
                        TextField("8000", text: $portDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }

                section(title: "Brain (LM Studio)",
                        footer: "Apply hot-reloads the client and refreshes the model list. No relaunch needed.") {
                    LabeledContent("Base URL") {
                        TextField("http://localhost:1234/v1", text: $lmURLDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                    }
                    LabeledContent("Model") {
                        modelPicker
                    }
                    LabeledContent("API key") {
                        SecureField("(blank for none)", text: $lmApiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                    }
                }

                section(title: "Microphone",
                        footer: "Robot mic uses Reachy Mini's 4-mic ReSpeaker array via WebRTC (run ./Sidecars/robot-mic/setup.sh once to install). Source change takes effect on the next Listen toggle.") {
                    Picker("Source", selection: $micSourceDraft) {
                        Text("Robot mic (Reachy 4-mic array)").tag("robot")
                        Text("Mac mic (built-in / system default)").tag("mac")
                    }
                    .pickerStyle(.radioGroup)
                }

                section(title: "Voice (TTS)",
                        footer: "Chatterbox uses your cloned voice from ~/Library/Application Support/Rocky/voice/. Engine change takes effect on next launch.") {
                    Picker("Engine", selection: $ttsBackendDraft) {
                        Text("System voice (say)").tag("say")
                        Text("Chatterbox FP16 (cloned)").tag("chatterbox")
                    }
                    .pickerStyle(.radioGroup)
                }

                section(title: "Persona",
                        footer: "System prompt. Edit to change Rocky's voice and rules.") {
                    TextEditor(text: $personaDraft)
                        .font(.body.monospaced())
                        .frame(minHeight: 180)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.gray.opacity(0.3), lineWidth: 1)
                        )
                    HStack {
                        Spacer()
                        Button("Reset to default") {
                            personaDraft = SettingsStore.defaultPersona
                        }
                        .controlSize(.small)
                    }
                }

                HStack {
                    if let savedAt {
                        Text("Saved \(savedAt.formatted(.dateTime.hour().minute().second()))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apply") {
                        Task { await apply() }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
                }
            }
            .padding(20)
        }
        .onAppear { syncFromStore() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings").font(.title2.weight(.semibold))
            Text("Tune Rocky's connections and personality.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Model dropdown sourced from `services.availableLLMModels` (refreshed
    /// on every LM Studio probe). Falls back to a free-text field when LM
    /// Studio is unreachable so the user can still pre-configure a name.
    @ViewBuilder
    private var modelPicker: some View {
        let models = services.availableLLMModels
        if models.isEmpty {
            HStack(spacing: 6) {
                TextField("(LM Studio offline)", text: $lmModelDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Button {
                    Task { await services.probeLMStudioPublic() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-probe LM Studio")
                .controlSize(.small)
            }
        } else {
            HStack(spacing: 6) {
                Picker("", selection: $lmModelDraft) {
                    if !models.contains(lmModelDraft) && !lmModelDraft.isEmpty {
                        Text("\(lmModelDraft) (not loaded)").tag(lmModelDraft)
                    }
                    ForEach(models, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                Button {
                    Task { await services.probeLMStudioPublic() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-probe LM Studio")
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func section(
        title: String,
        footer: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
    }

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
