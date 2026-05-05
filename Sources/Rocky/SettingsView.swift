import SwiftUI

struct SettingsView: View {
    @Environment(AppServices.self) private var services

    @State private var hostDraft: String = ""
    @State private var portDraft: String = ""
    @State private var lmURLDraft: String = ""
    @State private var lmModelDraft: String = ""
    @State private var lmApiKeyDraft: String = ""
    @State private var personaDraft: String = ""
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
                        footer: "Apply hot-reloads the client. No relaunch needed.") {
                    LabeledContent("Base URL") {
                        TextField("http://localhost:1234/v1", text: $lmURLDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                    }
                    LabeledContent("Model") {
                        TextField("qwen2.5-7b-instruct", text: $lmModelDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                    }
                    LabeledContent("API key") {
                        SecureField("(blank for none)", text: $lmApiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                    }
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
    }

    private func syncFromStore() {
        hostDraft = services.settings.robotHost
        portDraft = String(services.settings.robotPort)
        lmURLDraft = services.settings.lmStudioURL
        lmModelDraft = services.settings.lmStudioModel
        lmApiKeyDraft = services.settings.lmStudioApiKey
        personaDraft = services.settings.persona
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
        await services.applySettings()
        savedAt = Date()
    }
}
