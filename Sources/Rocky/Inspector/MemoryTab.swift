import SwiftUI
import AppKit
import Memory
import Telemetry

/// Inspector → Memory. Use surface for Rocky's verbatim drawer store.
///
/// Settings → Memory owns the *configuration* (recall on/off, top-K).
/// This tab owns *use*: see how full memory is, write a quick note,
/// browse what's there, purge it. Per `docs/concepts/cockpit-design.md`
/// §3.4 this is the "you're in the inspector and want to peek at /
/// teach Rocky a thing" surface.
///
/// Layout, top to bottom:
///   - Header — Label + a refresh-count button
///   - Hero stat — drawer count as `.title2` monospaced
///   - "Remember…" inline write (mirrors the cockpit footer; intentional
///     redundancy so you don't have to context-switch out of the
///     inspector to file a fact)
///   - Recent drawers — last 8, one-line previews, click to expand
///   - "Configure recall…" link to Settings → Memory
///   - Destructive "Forget everything" with alert confirm
struct MemoryTab: View {
    @Environment(AppServices.self) private var services
    @State private var rememberDraft: String = ""
    @State private var rememberPin: Bool = false
    @State private var rememberConfirmation: String?
    @State private var recent: [MemoryService.Hit] = []
    @State private var loadingRecent: Bool = false
    @State private var expandedID: String?
    @State private var confirmingForget: Bool = false
    @State private var forgetWorking: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow
            heroStat
            rememberRow
            recentSection
            footerRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await loadRecent() }
        .onChange(of: services.memoryDrawerCount) { _, _ in
            Task { await loadRecent() }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Memory", systemImage: "tray.full")
                .font(.headline)
            Spacer()
            Button {
                Task {
                    await services.refreshMemoryCount()
                    await loadRecent()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Re-poll the sidecar for the current drawer count and recent list.")
        }
    }

    // MARK: - Hero stat

    private var heroStat: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(countText)
                .font(.title2.monospacedDigit().weight(.semibold))
                .contentTransition(.numericText())
                .animation(.snappy, value: services.memoryDrawerCount)
            Text(countSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var countText: String {
        let n = services.memoryDrawerCount
        if n < 0 { return "—" }
        if n == 1 { return "1 drawer" }
        return "\(n.formatted()) drawers"
    }

    private var countSubtitle: String {
        switch services.memorySidecarState {
        case .ready:    return "Stored locally — ~/Library/Application Support/Rocky/Memory."
        case .stopped:  return "Memory sidecar stopped — run Sidecars/mempalace/setup.sh."
        case .starting: return "Memory sidecar starting…"
        case .failing(let reason): return "Memory failing — \(reason)"
        case .circuitOpen: return "Memory sidecar in cooldown."
        }
    }

    // MARK: - Remember row

    private var rememberRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remember".uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: rememberPin ? "pin.fill" : "pin")
                    .foregroundStyle(rememberPin ? AnyShapeStyle(.yellow)
                                                  : AnyShapeStyle(.secondary))
                    .onTapGesture { rememberPin.toggle() }
                    .help(rememberPin
                          ? "Pinned: this memory is always recalled."
                          : "Click to pin: this memory will always be recalled.")
                TextField("A fact, preference, or note Rocky should keep…",
                          text: $rememberDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitRemember() }
                Button {
                    submitRemember()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(rememberDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let confirmation = rememberConfirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: rememberConfirmation)
    }

    // MARK: - Recent drawers

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent".uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                if loadingRecent {
                    ProgressView().controlSize(.small)
                }
            }
            if recent.isEmpty {
                Text(services.memorySidecarState == .ready
                     ? "No drawers yet. Try the Remember field above."
                     : "—")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(recent, id: \.idOrText) { hit in
                        DrawerRow(hit: hit,
                                   expanded: expandedID == hit.idOrText)
                            .onTapGesture {
                                expandedID = expandedID == hit.idOrText
                                    ? nil : hit.idOrText
                            }
                        if hit.idOrText != recent.last?.idOrText {
                            Divider()
                        }
                    }
                }
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 10) {
            Button {
                NSApp.sendAction(
                    Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("Configure recall…", systemImage: "gear")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Recall toggle, top-K, and persistence options live in Settings → Memory.")

            Spacer()

            Button(role: .destructive) {
                confirmingForget = true
            } label: {
                if forgetWorking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Forgetting…")
                    }
                } else {
                    Label("Forget everything", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(forgetWorking
                      || services.memoryDrawerCount == 0
                      || services.memorySidecarState != .ready)
            .alert("Forget every memory?",
                   isPresented: $confirmingForget) {
                Button("Cancel", role: .cancel) {}
                Button("Forget everything", role: .destructive) {
                    Task { await performForget() }
                }
            } message: {
                Text("Deletes every drawer Rocky has stored. He won't remember any prior conversations after this.")
            }
        }
    }

    // MARK: - Actions

    private func submitRemember() {
        let text = rememberDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let body = rememberPin ? "[pinned] " + text : text
        rememberDraft = ""
        Task {
            do {
                _ = try await services.memory.record(role: .system, text: body)
                await MainActor.run {
                    rememberConfirmation = "Filed"
                    rememberPin = false
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { rememberConfirmation = nil }
                await services.refreshMemoryCount()
                await loadRecent()
            } catch {
                await MainActor.run {
                    rememberConfirmation = "failed: \(error)"
                }
            }
        }
    }

    private func performForget() async {
        await MainActor.run { forgetWorking = true }
        _ = await services.forgetAllMemory()
        await MainActor.run {
            forgetWorking = false
            recent = []
        }
    }

    private func loadRecent() async {
        guard services.memorySidecarState == .ready else { return }
        await MainActor.run { loadingRecent = true }
        defer { Task { @MainActor in loadingRecent = false } }
        // Bias the recall toward generic content rather than a specific
        // query so we surface the most-recent drawers in roughly
        // recency order (mempalace's search is semantic — the empty
        // query is treated as "most recently added").
        do {
            let hits = try await services.memory.recall(query: " ", k: 8)
            await MainActor.run { recent = hits }
        } catch {
            await MainActor.run { recent = [] }
        }
    }
}

// MARK: - Row

private struct DrawerRow: View {
    let hit: MemoryService.Hit
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: hit.text.hasPrefix("[pinned]")
                       ? "pin.fill" : "tray")
                    .foregroundStyle(hit.text.hasPrefix("[pinned]")
                                       ? AnyShapeStyle(.yellow)
                                       : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                Text(hit.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let dist = hit.distance {
                    Text(String(format: "%.2f", dist))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private extension MemoryService.Hit {
    /// Stable identifier for SwiftUI ForEach: prefer the drawer id from
    /// mempalace, fall back to the text content if the sidecar didn't
    /// surface one (older payloads).
    var idOrText: String { id ?? text }
}
