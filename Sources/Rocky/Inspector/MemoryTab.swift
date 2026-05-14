import SwiftUI
import AppKit
import SceneKit
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
    @Environment(\.openSettings) private var openSettings
    @State private var rememberDraft: String = ""
    @State private var rememberPin: Bool = false
    @State private var rememberConfirmation: String?
    @State private var recent: [MemoryService.Hit] = []
    @State private var triples: [MemoryService.Triple] = []
    @State private var stats: MemoryService.GraphStats?
    @State private var loadingRecent: Bool = false
    @State private var loadingTriples: Bool = false
    @State private var expandedID: String?
    @State private var confirmingForget: Bool = false
    @State private var forgetWorking: Bool = false
    @State private var section: Section = .drawers
    @State private var graphExpanded: Bool = false

    enum Section: String, CaseIterable, Identifiable {
        case drawers = "Drawers"
        case facts   = "Facts"
        case graph   = "Graph"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            // The drawer-count hero stat and the Remember field
            // are only relevant in the Drawers section. Hide them
            // for Facts / Graph so those sections get the full
            // inspector height — the inspector is narrow and tall,
            // and the 3D graph in particular needs that real estate
            // to be readable.
            if section == .drawers {
                heroStat
                rememberRow
            }
            sectionPicker
            switch section {
            case .drawers: recentSection
            case .facts:   factsSection
            case .graph:   graphSection
            }
            footerRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await refresh() }
        .onChange(of: services.memoryDrawerCount) { _, _ in
            Task { await refresh() }
        }
    }

    private var sectionPicker: some View {
        Picker("", selection: $section) {
            ForEach(Section.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func refresh() async {
        await loadRecent()
        await loadTriples()
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
        // Prefer the filtered list count when we have one — that's the
        // truth the user is looking at directly below. The raw
        // `memoryDrawerCount` from the sidecar's `count()` RPC can
        // include malformed/empty entries that `listDrawers` filters
        // out, which previously produced a "1 drawer" header above
        // 30 empty rows.
        if !recent.isEmpty {
            let n = recent.count
            return n == 1 ? "1 drawer" : "\(n.formatted()) drawers"
        }
        let n = services.memoryDrawerCount
        if n < 0 { return "—" }
        if n == 0 { return "0 drawers" }
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
                        DrawerRow(
                            hit: hit,
                            expanded: expandedID == hit.idOrText,
                            canDelete: hit.id != nil,
                            onDelete: {
                                Task { await deleteDrawer(hit) }
                            }
                        )
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
                // openSettings is the SwiftUI-native way to surface
                // the Settings scene; the older
                // `NSApp.sendAction(Selector("showSettingsWindow:"))`
                // pattern only fires correctly when the responder
                // chain has the right hookup, which SwiftUI apps
                // sometimes lack. openSettings has no responder
                // dependency so it works reliably.
                openSettings()
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
            // Don't gate on memoryDrawerCount — its source (the
            // `count` RPC) can report 0 while drawers actually exist
            // in non-default rooms, which previously left users
            // unable to click "Forget everything" on a palace that
            // wasn't actually empty. forget_all is idempotent on a
            // truly empty palace, so always enable when the sidecar
            // is up.
            .disabled(forgetWorking
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
        // Clear ALL local state — drawers, facts, graph stats. The
        // sidecar's forget_all now wipes drawers AND invalidates KG
        // triples, so a kgTimeline call would return an empty set
        // for live facts. Doing it locally too avoids a flash of
        // stale data while the re-fetch lands.
        await MainActor.run {
            forgetWorking = false
            recent = []
            triples = []
            stats = nil
        }
        // Re-fetch from the sidecar so any leftover state (e.g.
        // tombstoned KG entries that still surface via timeline) is
        // reflected accurately.
        await refresh()
    }

    // MARK: - Facts section

    private var factsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Facts".uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                if let s = stats {
                    Text("\(s.triples) triples · \(s.entities) entities · \(s.predicates) predicates")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if loadingTriples {
                    ProgressView().controlSize(.small)
                }
            }
            if triples.isEmpty {
                Text("No facts yet. Rocky files entries to his knowledge graph automatically as he learns.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(triples.enumerated()), id: \.offset) { idx, t in
                        FactRow(triple: t)
                        if idx < triples.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Graph section

    private var graphSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Graph".uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                if let s = stats {
                    Text("\(s.entities) entities · \(s.triples) connections")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if loadingTriples {
                    ProgressView().controlSize(.small)
                }
                Button {
                    graphExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(triples.isEmpty)
                .help("Open the graph in a full-window view.")
            }
            graphTile
                // Square thumbnail: the inspector is narrow, and a
                // 3D graph cluster reads as a tiny dot in a long
                // thin column. Aspect 1:1 against the inspector's
                // available width gives an honest preview; the
                // pop-out button hands the user a full-window view
                // when they want to actually navigate it.
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sheet(isPresented: $graphExpanded) {
            ExpandedGraphSheet(
                triples: triples,
                stats: stats,
                isPresented: $graphExpanded
            )
        }
    }

    @ViewBuilder
    private var graphTile: some View {
        if triples.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                VStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("Graph is empty")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Bubbles appear as Rocky learns who and what you talk about.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                        .padding(.horizontal, 12)
                }
            }
        } else {
            KnowledgeGraph3D(triples: triples)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.06, green: 0.07, blue: 0.12),
                            Color(red: 0.02, green: 0.03, blue: 0.06),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private func loadTriples() async {
        guard services.memorySidecarState == .ready else { return }
        await MainActor.run { loadingTriples = true }
        defer { Task { @MainActor in loadingTriples = false } }
        do {
            let timeline = try await services.memory.kgTimeline()
            let s = try await services.memory.kgStats()
            await MainActor.run {
                self.triples = timeline
                self.stats = s
            }
        } catch {
            await MainActor.run {
                self.triples = []
                self.stats = nil
            }
        }
    }

    private func loadRecent() async {
        guard services.memorySidecarState == .ready else { return }
        await MainActor.run { loadingRecent = true }
        defer { Task { @MainActor in loadingRecent = false } }
        // Chronological list, not semantic recall. The previous
        // `recall(query: " ")` returned zero hits because mempalace's
        // semantic search doesn't handle whitespace queries — the
        // Memory tab would then say "No drawers yet" even when
        // `count` was non-zero.
        do {
            let hits = try await services.memory.listDrawers(limit: 50)
            await MainActor.run { recent = hits }
        } catch {
            await MainActor.run { recent = [] }
        }
    }

    fileprivate func deleteDrawer(_ hit: MemoryService.Hit) async {
        guard let id = hit.id else { return }
        do {
            _ = try await services.memory.deleteDrawer(id: id)
            // Optimistic local removal so the row drops out
            // immediately; loadRecent re-syncs from the truth.
            await MainActor.run {
                recent.removeAll { $0.idOrText == hit.idOrText }
            }
            await services.refreshMemoryCount()
            await loadRecent()
        } catch {
            // Silent failure for now — non-fatal; user can retry
            // or use Forget Everything as the nuclear option.
        }
    }
}

// MARK: - Row

private struct DrawerRow: View {
    let hit: MemoryService.Hit
    let expanded: Bool
    let canDelete: Bool
    let onDelete: () -> Void

    @State private var hovering: Bool = false

    private var pinned: Bool { hit.text.hasPrefix("[pinned]") }

    /// Show pin / user / assistant / system / tool icons. Pin wins
    /// over role since the user explicitly tagged it.
    private var rowIcon: (name: String, tint: Color) {
        if pinned { return ("pin.fill", .yellow) }
        switch hit.role {
        case "user":      return ("person.fill", .blue)
        case "assistant": return ("sparkles", .accentColor)
        case "system":    return ("gear", .gray)
        case "tool":      return ("wrench.adjustable", .orange)
        default:          return ("tray", .secondary)
        }
    }

    /// Strip the `[pinned] ` prefix from the display so the user
    /// sees the actual content, not the marker.
    private var displayText: String {
        pinned
            ? String(hit.text.dropFirst("[pinned] ".count))
            : hit.text
    }

    /// Format ISO-8601 timestamp into a relative string ("2m ago",
    /// "yesterday"). Falls back to the raw string if parsing fails.
    private var relativeTime: String? {
        guard let ts = hit.ts else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: ts)
            ?? ISO8601DateFormatter().date(from: ts)
        guard let date = parsed else { return nil }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: rowIcon.name)
                .foregroundStyle(rowIcon.tint)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayText)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(expanded ? nil : 2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if let role = hit.role {
                        Text(role.capitalized)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if let when = relativeTime {
                        Text(when)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if let dist = hit.distance {
                        Text(String(format: "sim %.2f", dist))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1.0 : 0.0)
                .help("Forget this memory.")
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

private extension MemoryService.Hit {
    /// Stable identifier for SwiftUI ForEach: prefer the drawer id from
    /// mempalace, fall back to the text content if the sidecar didn't
    /// surface one (older payloads).
    var idOrText: String { id ?? text }
}

// MARK: - Fact row

private struct FactRow: View {
    let triple: MemoryService.Triple

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.right.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(triple.subject)
                        .font(.callout.weight(.medium))
                    Text(triple.predicate.replacingOccurrences(of: "_", with: " "))
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.tertiary.opacity(0.3))
                        )
                        .foregroundStyle(.secondary)
                    Text(triple.object)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                if triple.validFrom != nil || triple.validTo != nil {
                    HStack(spacing: 6) {
                        if let from = triple.validFrom {
                            Text("from \(from)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        if let to = triple.validTo {
                            Text("to \(to)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Expanded graph sheet

/// Full-window pop-out of the 3D knowledge graph. Presented modally
/// from MemoryTab's expand button so the user can actually navigate
/// a dense cluster — the inspector's narrow column is fine as a
/// preview but unusable for serious inspection.
private struct ExpandedGraphSheet: View {
    let triples: [MemoryService.Triple]
    let stats: MemoryService.GraphStats?
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Knowledge graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                if let s = stats {
                    Text("\(s.entities) entities · \(s.triples) connections")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            KnowledgeGraph3D(triples: triples)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.06, green: 0.07, blue: 0.12),
                            Color(red: 0.02, green: 0.03, blue: 0.06),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
        .frame(minWidth: 720, idealWidth: 1100, minHeight: 540, idealHeight: 820)
    }
}


// MARK: - 3D knowledge graph

/// SceneKit-backed 3D visualization of mempalace's temporal knowledge
/// graph. Entities (every distinct subject + object across all
/// triples) become spheres positioned by a 3D force-directed layout
/// (Fruchterman-Reingold); triples become edges connecting their
/// endpoints; each entity's sphere radius and colour scale with its
/// degree so hubs read big and warm, leaves read small and cool.
///
/// Interaction:
///   - Drag to orbit the scene.
///   - Scroll to zoom.
///   - Hover a node to see its name.
/// The scene is otherwise stationary — no auto-rotate, no kinetic
/// motion. It only moves when the user moves it.
///
/// Layout cost: O(N² × iterations). For 70 entities × 300 iterations
/// that's ~1.5 M pair operations, runs in well under a second on
/// the main actor. Memoised on `triples` so it doesn't recompute
/// during routine SwiftUI updates.
/// SCNView subclass that re-frames its camera every time the view
/// resizes so the laid-out cluster always fits the available
/// real-estate, regardless of the inspector's current dimensions.
/// The cluster's bounding sphere radius is stamped in at scene-build
/// time; `layout()` recomputes the required camera distance from
/// `bounds` (which gives us the actual aspect ratio) and the
/// camera's vertical FOV.
final class AutoFramingSCNView: SCNView {
    /// Bounding-sphere radius of the laid-out node cluster, in scene
    /// units. Set by `KnowledgeGraph3D.buildScene` after layout.
    var clusterRadius: CGFloat = 10
    /// Vertical FOV of `cameraNode.camera` (degrees). Mirrored here
    /// so we don't have to dig through the SCNCamera every layout.
    var verticalFOV: CGFloat = 50
    /// The camera node whose Z position we re-frame on resize.
    weak var cameraNode: SCNNode?
    /// Multiplier on the tight-fit distance so the cluster isn't
    /// crammed edge-to-edge.
    var framingMargin: CGFloat = 1.22

    private let tooltip = NodeTooltipView()
    private var trackingArea: NSTrackingArea?

    override func layout() {
        super.layout()
        reframeCamera()
        if tooltip.superview !== self {
            addSubview(tooltip, positioned: .above, relativeTo: nil)
        }
    }

    func reframeCamera() {
        guard let cam = cameraNode, bounds.height > 0, bounds.width > 0 else {
            return
        }
        let aspect = max(0.25, bounds.width / bounds.height)
        let fovV = verticalFOV * .pi / 180
        // Horizontal FOV derived from the viewport aspect — SCNCamera
        // applies the vertical FOV literally; the horizontal one is
        // implied by the viewport. Distance must satisfy whichever
        // axis is tighter so the cluster fits both dimensions.
        let fovH = 2 * atan(tan(fovV / 2) * aspect)
        let distV = clusterRadius / max(0.01, tan(fovV / 2))
        let distH = clusterRadius / max(0.01, tan(fovH / 2))
        let dist = max(distV, distH) * framingMargin
        cam.position = SCNVector3(0, 0, Float(dist))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // .activeAlways so hover works even when the inspector
        // panel isn't key — the user is typically focused on the
        // cockpit window, not the inspector subpanel.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited,
                      .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateTooltip(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        tooltip.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        // Hide during orbit/drag so the tooltip doesn't sit stale
        // over a node that's flying past. mouseMoved on the next
        // hover will bring it back.
        tooltip.isHidden = true
        super.mouseDown(with: event)
    }

    /// Hit-test at `point` (view coords) and either show the entity
    /// name at the cursor or hide the tooltip if no node is under it.
    private func updateTooltip(at point: NSPoint) {
        let hits = hitTest(point, options: [
            .searchMode: NSNumber(value: SCNHitTestSearchMode.closest.rawValue),
            .ignoreHiddenNodes: true,
        ])
        let entity = hits.lazy.compactMap { result -> String? in
            var n: SCNNode? = result.node
            while let cur = n {
                if let name = cur.name, name.hasPrefix("entity:") {
                    return String(name.dropFirst("entity:".count))
                }
                n = cur.parent
            }
            return nil
        }.first

        guard let entity else {
            tooltip.isHidden = true
            return
        }

        tooltip.setText(entity)
        // Offset to upper-right of cursor, clamped to view bounds so
        // the tooltip never gets cut off at the edges.
        let pad: CGFloat = 12
        var origin = NSPoint(x: point.x + pad, y: point.y + pad)
        if origin.x + tooltip.frame.width > bounds.maxX - 4 {
            origin.x = point.x - tooltip.frame.width - pad
        }
        if origin.y + tooltip.frame.height > bounds.maxY - 4 {
            origin.y = point.y - tooltip.frame.height - pad
        }
        origin.x = max(4, origin.x)
        origin.y = max(4, origin.y)
        tooltip.setFrameOrigin(origin)
        tooltip.isHidden = false
        // Make sure it stays on top of any subviews SceneKit adds.
        addSubview(tooltip, positioned: .above, relativeTo: nil)
    }
}

/// Floating label that follows the cursor when hovering a node in
/// `AutoFramingSCNView`. Subtle dark pill so it reads on the dark
/// graph background without competing with the cluster.
final class NodeTooltipView: NSView {
    private let textField: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        tf.textColor = NSColor(white: 0.96, alpha: 1)
        tf.backgroundColor = .clear
        tf.drawsBackground = false
        tf.isBordered = false
        tf.isEditable = false
        tf.isSelectable = false
        return tf
    }()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor(white: 0.05, alpha: 0.92).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }

    /// Hover-only — must not steal events from the camera controller.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setText(_ s: String) {
        textField.stringValue = s
        let size = textField.intrinsicContentSize
        setFrameSize(NSSize(
            width: ceil(size.width + 16),
            height: ceil(size.height + 8)
        ))
    }
}

private struct KnowledgeGraph3D: NSViewRepresentable {
    let triples: [MemoryService.Triple]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AutoFramingSCNView {
        let view = AutoFramingSCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .clear
        view.preferredFramesPerSecond = 60
        installScene(triples: triples, into: view)
        context.coordinator.lastTriplesKey = key(for: triples)
        return view
    }

    func updateNSView(_ view: AutoFramingSCNView, context: Context) {
        // Only rebuild when the triple set actually changed —
        // avoids resetting the camera + autoplay on every SwiftUI
        // redraw. (Viewport resizes are handled by AutoFramingSCNView
        // itself in layout(); they don't need a scene rebuild.)
        let next = key(for: triples)
        if context.coordinator.lastTriplesKey != next {
            installScene(triples: triples, into: view)
            context.coordinator.lastTriplesKey = next
        }
    }

    private func installScene(
        triples: [MemoryService.Triple], into view: AutoFramingSCNView
    ) {
        let result = buildScene(for: triples)
        view.scene = result.scene
        view.cameraNode = result.cameraNode
        view.clusterRadius = result.boundingRadius
        view.verticalFOV = result.verticalFOV
        view.reframeCamera()
    }

    final class Coordinator {
        var lastTriplesKey: String = ""
    }

    /// Cheap stable identifier for the triple set so SwiftUI's
    /// re-render machinery doesn't trigger a layout recompute
    /// when nothing changed.
    private func key(for triples: [MemoryService.Triple]) -> String {
        triples.map { "\($0.subject)|\($0.predicate)|\($0.object)" }
            .sorted()
            .joined(separator: ";")
    }

    // MARK: - Scene build

    struct SceneResult {
        let scene: SCNScene
        let cameraNode: SCNNode
        /// Radius of the smallest sphere centred at the origin that
        /// contains every node sphere (centre + sphere radius). The
        /// view uses this to compute the camera framing distance.
        let boundingRadius: CGFloat
        let verticalFOV: CGFloat
    }

    private func buildScene(for triples: [MemoryService.Triple]) -> SceneResult {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        // Collect entities + degrees.
        var degree: [String: Int] = [:]
        for t in triples {
            degree[t.subject, default: 0] += 1
            degree[t.object, default: 0] += 1
        }
        let entities = Array(degree.keys)
        let verticalFOV: CGFloat = 50

        // Build a minimal scene (camera only) for the empty case so
        // the AutoFramingSCNView still has something sensible to
        // reference when triples haven't loaded.
        guard !entities.isEmpty else {
            let cam = SCNCamera()
            cam.fieldOfView = verticalFOV
            cam.zNear = 0.1
            cam.zFar = 500
            let cameraNode = SCNNode()
            cameraNode.camera = cam
            cameraNode.position = SCNVector3(0, 0, 10)
            scene.rootNode.addChildNode(cameraNode)
            return SceneResult(
                scene: scene, cameraNode: cameraNode,
                boundingRadius: 5, verticalFOV: verticalFOV
            )
        }

        // Compute 3D layout.
        let positions = Self.forceDirectedLayout(
            entities: entities, triples: triples, degree: degree
        )

        // Content container — every sphere / edge goes under this.
        // Kept separate from the camera rig + lights so it could be
        // animated independently if we ever want to; today it stays
        // still and only moves under explicit user interaction.
        let contentNode = SCNNode()
        scene.rootNode.addChildNode(contentNode)

        // Ambient light. Brighter than before (0.25 → 0.55) so the
        // far side of the cluster never goes pitch black when the
        // user orbits past the key+rim sweet spot — even with the
        // camera-attached studio lighting below, the back face
        // wants a fill so colours stay readable.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor(white: 0.55, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        // Two-axis colour coding:
        //   - NODES coloured by community (label-propagation on the
        //     undirected graph). Entities that are densely
        //     interconnected — e.g. "tim_cook" + "apple" + "iphone"
        //     — get the same colour; loose entities get their own
        //     hue. Brightness within a community modulates by
        //     degree percentile so hubs still stand out.
        //   - EDGES coloured by predicate. Every distinct
        //     relationship label (e.g. "founded", "works_at",
        //     "born_in") gets a stable hue, so visual texture maps
        //     to relationship type.
        let communities = Self.detectCommunities(
            entities: entities, triples: triples
        )
        let communityIDs = Array(Set(communities.values)).sorted()
        let communityHue: [Int: CGFloat] = Dictionary(
            uniqueKeysWithValues: communityIDs.enumerated().map {
                ($1, Self.goldenRatioHue(index: $0))
            }
        )
        let predicateNames = Array(Set(triples.map { $0.predicate })).sorted()
        let predicateHue: [String: CGFloat] = Dictionary(
            uniqueKeysWithValues: predicateNames.enumerated().map {
                ($1, Self.goldenRatioHue(index: $0, offset: 0.43))
            }
        )

        let maxDeg = degree.values.max() ?? 1

        // Spheres + labels.
        for entity in entities {
            let d = degree[entity] ?? 1
            let position = positions[entity] ?? SCNVector3(0, 0, 0)
            let pct = Double(d) / Double(max(1, maxDeg))
            let radius: CGFloat = CGFloat(0.18 + 0.45 * pct)
            let community = communities[entity] ?? 0
            let hue = communityHue[community] ?? 0
            // Saturation + brightness modulated by degree —
            // higher-degree nodes in a community read brighter +
            // more saturated, leaves are subtler same-hue cousins.
            let saturation: CGFloat = 0.55 + 0.30 * CGFloat(pct)
            let brightness: CGFloat = 0.78 + 0.18 * CGFloat(pct)
            let nodeColor = NSColor(
                hue: hue, saturation: saturation,
                brightness: brightness, alpha: 1.0
            )
            // Emission is the hue itself at moderate alpha so the
            // colour is ALWAYS visible — even on the unlit hemisphere
            // and even when zoomed in past where direct lighting
            // matters. Without this, close-in views can wash the
            // node to grey.
            let emissionColor = NSColor(
                hue: hue, saturation: saturation,
                brightness: brightness, alpha: 0.50
            )
            let sphere = SCNSphere(radius: radius)
            sphere.segmentCount = 32
            // Blinn instead of physicallyBased — PBR without an IBL
            // environment map produces a giant specular hotspot from
            // the camera-attached key light, and zooming in lets
            // that hotspot dominate the visible surface, washing the
            // diffuse colour to grey. Blinn gives predictable
            // diffuse-driven colour at every zoom level.
            sphere.firstMaterial?.lightingModel = .blinn
            sphere.firstMaterial?.diffuse.contents = nodeColor
            // Faint, slightly-tinted specular so highlights add
            // shape without overpowering the diffuse colour.
            sphere.firstMaterial?.specular.contents = NSColor(white: 0.18, alpha: 1)
            sphere.firstMaterial?.shininess = 18
            sphere.firstMaterial?.emission.contents = emissionColor
            let node = SCNNode(geometry: sphere)
            node.position = position
            node.name = "entity:\(entity)"
            contentNode.addChildNode(node)
            // Labels are hover-only — `AutoFramingSCNView` renders a
            // floating AppKit tooltip on mouseMoved. Keeps the graph
            // visually clean and avoids the wall-of-text problem on
            // dense clusters.
        }

        // Edges as thin cylinders, colour-coded by predicate so
        // relationship types are visually groupable. Cylinders read
        // better than line primitives in 3D — they catch light and
        // convey direction.
        for t in triples {
            guard let a = positions[t.subject], let b = positions[t.object]
            else { continue }
            let hue = predicateHue[t.predicate] ?? 0.55
            let edgeColor = NSColor(
                hue: hue, saturation: 0.62, brightness: 0.92, alpha: 0.65
            )
            let edge = makeEdge(from: a, to: b, color: edgeColor, thickness: 0.03)
            edge.name = "edge:\(t.subject)→\(t.predicate)→\(t.object)"
            contentNode.addChildNode(edge)
        }

        // Compute the actual cluster bounding-sphere radius —
        // distance from the origin to the farthest node sphere's
        // far edge. AutoFramingSCNView uses this to size the camera
        // pullback against whatever viewport SwiftUI gives us, so
        // the cluster always fills the available real-estate.
        var maxR: CGFloat = 0
        for entity in entities {
            let p = positions[entity] ?? SCNVector3(0, 0, 0)
            let d = degree[entity] ?? 1
            let pct = Double(d) / Double(max(1, maxDeg))
            let nodeRadius: CGFloat = CGFloat(0.18 + 0.45 * pct)
            let r = sqrt(CGFloat(p.x * p.x + p.y * p.y + p.z * p.z)) + nodeRadius
            if r > maxR { maxR = r }
        }
        // Floor at 6 so a 1-node graph isn't framed so tightly that
        // the sphere fills the viewport edge-to-edge.
        let boundingRadius = max(6, maxR)

        // Camera rig. Position is a placeholder — AutoFramingSCNView's
        // layout() will re-pull-back based on viewport aspect. The
        // key + rim lights are children of the camera so they ORBIT
        // WITH IT: whichever side of the cluster you're looking at
        // is always the lit side. Without this, dragging past the
        // world-space light cones leaves nodes in deep shadow and
        // their colours wash out to grey.
        let cameraNode = SCNNode()
        let cam = SCNCamera()
        cam.fieldOfView = verticalFOV
        cam.zNear = 0.1
        cam.zFar = 1000
        // HDR off: SceneKit's HDR tonemapper desaturates bright
        // surfaces (notably specular highlights from camera-rigged
        // lights when zoomed in). Standard LDR + Blinn shading
        // keeps node colour intact at every zoom level.
        cam.wantsHDR = false
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, 0, Float(boundingRadius * 3))
        scene.rootNode.addChildNode(cameraNode)

        // Key light — warm, slightly above + right of the camera.
        // Directional lights point along their local -Z, so an
        // identity-rotated child of the camera lights what the
        // camera looks at; we tilt slightly for shape.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.color = NSColor(red: 1.0, green: 0.94, blue: 0.86, alpha: 1)
        key.light?.intensity = 850
        key.eulerAngles = SCNVector3(-Float.pi / 10, Float.pi / 8, 0)
        cameraNode.addChildNode(key)

        // Rim — cool, opposite side, lower intensity. Gives the
        // spheres a silhouette edge.
        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.color = NSColor(red: 0.6, green: 0.75, blue: 1.0, alpha: 1)
        rim.light?.intensity = 450
        rim.eulerAngles = SCNVector3(Float.pi / 12, -Float.pi / 6, 0)
        cameraNode.addChildNode(rim)

        return SceneResult(
            scene: scene, cameraNode: cameraNode,
            boundingRadius: boundingRadius, verticalFOV: verticalFOV
        )
    }

    private func makeEdge(
        from a: SCNVector3, to b: SCNVector3,
        color: NSColor, thickness: CGFloat
    ) -> SCNNode {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dz = b.z - a.z
        let length = sqrt(dx * dx + dy * dy + dz * dz)
        let cylinder = SCNCylinder(radius: thickness, height: CGFloat(length))
        cylinder.firstMaterial?.diffuse.contents = color
        cylinder.firstMaterial?.lightingModel = .constant
        cylinder.firstMaterial?.isDoubleSided = true
        let node = SCNNode(geometry: cylinder)
        // Position midpoint between endpoints.
        node.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        // Orient along (b - a). Default cylinder runs along Y axis.
        let up = SCNVector3(0, 1, 0)
        let dir = SCNVector3(dx / length, dy / length, dz / length)
        node.orientation = quaternion(from: up, to: dir)
        return node
    }

    /// Returns a quaternion that rotates `from` onto `to`.
    private func quaternion(from a: SCNVector3, to b: SCNVector3) -> SCNQuaternion {
        let dot = a.x * b.x + a.y * b.y + a.z * b.z
        if dot > 0.99999 {
            return SCNQuaternion(0, 0, 0, 1)  // identity
        }
        if dot < -0.99999 {
            // 180° rotation around any perpendicular axis.
            return SCNQuaternion(1, 0, 0, 0)
        }
        // Cross product gives the rotation axis.
        let cx = a.y * b.z - a.z * b.y
        let cy = a.z * b.x - a.x * b.z
        let cz = a.x * b.y - a.y * b.x
        let s = sqrt((1 + dot) * 2)
        let invs = 1 / s
        return SCNQuaternion(cx * invs, cy * invs, cz * invs, s / 2)
    }

    /// Map a degree percentile (0..1) to a color — cool blue → teal
    /// → warm orange/red as connectedness rises.
    static func color(forDegreePercentile p: Double, alpha: CGFloat = 1.0) -> NSColor {
        // Three-stop gradient.
        let stops: [(t: Double, r: Double, g: Double, b: Double)] = [
            (0.0,  0.30, 0.55, 0.95),  // blue (leaf)
            (0.5,  0.30, 0.85, 0.80),  // teal (mid)
            (1.0,  1.00, 0.60, 0.30),  // warm orange (hub)
        ]
        let clamped = max(0, min(1, p))
        for i in 0..<stops.count - 1 {
            let lo = stops[i], hi = stops[i + 1]
            if clamped >= lo.t && clamped <= hi.t {
                let span = hi.t - lo.t
                let f = span > 0 ? (clamped - lo.t) / span : 0
                return NSColor(
                    red: CGFloat(lo.r + (hi.r - lo.r) * f),
                    green: CGFloat(lo.g + (hi.g - lo.g) * f),
                    blue: CGFloat(lo.b + (hi.b - lo.b) * f),
                    alpha: alpha
                )
            }
        }
        return NSColor(
            red: CGFloat(stops.last!.r),
            green: CGFloat(stops.last!.g),
            blue: CGFloat(stops.last!.b),
            alpha: alpha
        )
    }

    /// Label-propagation community detection. Treats triples as
    /// undirected edges, gives every entity a unique starting label,
    /// then iteratively replaces each entity's label with the most
    /// common label among its neighbours. Converges fast (~10
    /// iterations for ~70 nodes) and produces stable community
    /// assignments per entity.
    ///
    /// Returns `entity → communityID` mapping. Community IDs are
    /// arbitrary integers, but the SAME entity ends up in the same
    /// community across builds because we iterate in sorted order
    /// (deterministic tiebreak).
    static func detectCommunities(
        entities: [String],
        triples: [MemoryService.Triple]
    ) -> [String: Int] {
        // Build undirected adjacency.
        var adj: [String: Set<String>] = [:]
        for e in entities { adj[e] = [] }
        for t in triples {
            adj[t.subject, default: []].insert(t.object)
            adj[t.object, default: []].insert(t.subject)
        }
        // Init labels — each entity gets its own.
        var labels: [String: Int] = [:]
        for (idx, e) in entities.sorted().enumerated() {
            labels[e] = idx
        }
        // Iterate. Sorted entity order keeps the propagation
        // deterministic; otherwise ties (two equally-popular
        // neighbour labels) would resolve differently per run.
        let iterations = 12
        for _ in 0..<iterations {
            var changed = false
            for e in entities.sorted() {
                let neighbours = adj[e] ?? []
                guard !neighbours.isEmpty else { continue }
                // Count neighbour labels; tiebreak: lower id wins.
                var counts: [Int: Int] = [:]
                for n in neighbours {
                    if let l = labels[n] {
                        counts[l, default: 0] += 1
                    }
                }
                guard let best = counts.max(by: {
                    $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key)
                })?.key else { continue }
                if labels[e] != best {
                    labels[e] = best
                    changed = true
                }
            }
            if !changed { break }
        }
        return labels
    }

    /// Distributes hues around the colour wheel using the golden
    /// ratio so consecutive indices land in maximally-distant hues.
    /// `offset` shifts the whole sequence so we can give nodes one
    /// palette and edges a different one without overlap.
    static func goldenRatioHue(index: Int, offset: CGFloat = 0) -> CGFloat {
        let phi: CGFloat = 0.6180339887
        let h = CGFloat(index) * phi + offset
        return h - floor(h)
    }

    // MARK: - Layout

    /// 3D Fruchterman-Reingold force-directed layout. Repulsion
    /// between every pair, attraction along edges, cooled over
    /// iterations. Returns a position per entity centred near the
    /// origin.
    /// Community-aware 3D force-directed layout. Three phases:
    ///
    /// 1. **Community detection** — label propagation groups densely
    ///    connected entities. Each community gets its own "region"
    ///    of 3D space, so the spatial layout reflects the semantic
    ///    structure of the graph.
    ///
    /// 2. **Seed placement** — community centroids placed on a
    ///    sphere shell using the Fibonacci/golden-ratio sphere
    ///    distribution (max separation between centroids regardless
    ///    of count). Each entity starts at its community's centroid
    ///    + small jitter.
    ///
    /// 3. **Force simulation** with four force types tuned for
    ///    community separation:
    ///      - **Repulsion** between every pair (so nodes don't
    ///        collapse onto each other).
    ///      - **Intra-community attraction** along edges within the
    ///        same community — strong, pulls cluster members
    ///        together.
    ///      - **Inter-community attraction** along edges across
    ///        communities — weak, prevents disconnected groups from
    ///        flying apart but doesn't let them merge.
    ///      - **Centroid gravity** — each node is gently pulled
    ///        toward its community's centroid so communities stay
    ///        coherent as distinct regions instead of bleeding into
    ///        each other.
    static func forceDirectedLayout(
        entities: [String],
        triples: [MemoryService.Triple],
        degree: [String: Int]
    ) -> [String: SCNVector3] {
        guard !entities.isEmpty else { return [:] }
        let n = entities.count

        // 1. Detect communities (same algo the colouring uses).
        let communities = detectCommunities(entities: entities, triples: triples)
        let communityList = Array(Set(communities.values)).sorted()
        let communityCount = max(1, communityList.count)

        // 2. Place community centroids on a Fibonacci sphere of
        //    radius `shellRadius`. Wider shell for more communities
        //    so they don't crowd.
        let shellRadius: CGFloat = CGFloat(8 + Double(communityCount) * 1.6)
        var centroids: [Int: (x: CGFloat, y: CGFloat, z: CGFloat)] = [:]
        let phi: CGFloat = .pi * (3.0 - sqrt(5.0))  // golden angle
        for (i, cid) in communityList.enumerated() {
            // Single community → centre. Multiple → fibonacci sphere.
            if communityCount == 1 {
                centroids[cid] = (0, 0, 0)
                continue
            }
            let y = 1 - (CGFloat(i) / CGFloat(communityCount - 1)) * 2  // [-1, 1]
            let r = sqrt(1 - y * y)
            let theta = phi * CGFloat(i)
            centroids[cid] = (
                shellRadius * cos(theta) * r,
                shellRadius * y,
                shellRadius * sin(theta) * r
            )
        }

        // Seed positions: community centroid + small deterministic jitter.
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(entities.sorted().joined().hashValue)))
        var px = [String: CGFloat](minimumCapacity: n)
        var py = [String: CGFloat](minimumCapacity: n)
        var pz = [String: CGFloat](minimumCapacity: n)
        for entity in entities {
            let cid = communities[entity] ?? 0
            let c = centroids[cid] ?? (0, 0, 0)
            let j: CGFloat = 1.8
            px[entity] = c.x + CGFloat(rng.nextDouble() * Double(j) - Double(j) / 2)
            py[entity] = c.y + CGFloat(rng.nextDouble() * Double(j) - Double(j) / 2)
            pz[entity] = c.z + CGFloat(rng.nextDouble() * Double(j) - Double(j) / 2)
        }

        // 3. Force simulation.
        let area: CGFloat = CGFloat(max(64, n * 12))
        let k: CGFloat = sqrt(area / CGFloat(n))
        let intraEdgeMul: CGFloat = 1.8   // strong pull within community
        let interEdgeMul: CGFloat = 0.35  // weak pull across communities
        let centroidGravity: CGFloat = 0.10
        let iterations = 400
        var temperature: CGFloat = k * 1.5

        for _ in 0..<iterations {
            var dx = [String: CGFloat](minimumCapacity: n)
            var dy = [String: CGFloat](minimumCapacity: n)
            var dz = [String: CGFloat](minimumCapacity: n)
            for e in entities { dx[e] = 0; dy[e] = 0; dz[e] = 0 }

            // Repulsion — every pair.
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let a = entities[i], b = entities[j]
                    let ex = px[a]! - px[b]!
                    let ey = py[a]! - py[b]!
                    let ez = pz[a]! - pz[b]!
                    var dist = sqrt(ex * ex + ey * ey + ez * ez)
                    if dist < 0.001 { dist = 0.001 }
                    let force = (k * k) / dist
                    let fx = ex / dist * force
                    let fy = ey / dist * force
                    let fz = ez / dist * force
                    dx[a]! += fx; dy[a]! += fy; dz[a]! += fz
                    dx[b]! -= fx; dy[b]! -= fy; dz[b]! -= fz
                }
            }

            // Edge attraction — split by intra- vs inter-community.
            for t in triples {
                guard let pax = px[t.subject], let pay = py[t.subject], let paz = pz[t.subject],
                      let pbx = px[t.object], let pby = py[t.object], let pbz = pz[t.object]
                else { continue }
                let ex = pax - pbx
                let ey = pay - pby
                let ez = paz - pbz
                let dist = max(sqrt(ex * ex + ey * ey + ez * ez), 0.001)
                let mul = (communities[t.subject] == communities[t.object])
                    ? intraEdgeMul
                    : interEdgeMul
                let force = (dist * dist) / k * mul
                let fx = ex / dist * force
                let fy = ey / dist * force
                let fz = ez / dist * force
                dx[t.subject]! -= fx; dy[t.subject]! -= fy; dz[t.subject]! -= fz
                dx[t.object]!  += fx; dy[t.object]!  += fy; dz[t.object]!  += fz
            }

            // Centroid gravity — each node pulled gently toward its
            // community's centroid so clusters stay coherent.
            for e in entities {
                let cid = communities[e] ?? 0
                guard let c = centroids[cid] else { continue }
                let gx = c.x - px[e]!
                let gy = c.y - py[e]!
                let gz = c.z - pz[e]!
                dx[e]! += gx * centroidGravity
                dy[e]! += gy * centroidGravity
                dz[e]! += gz * centroidGravity
            }

            // Apply displacement with temperature cap.
            for e in entities {
                let mx = dx[e]!, my = dy[e]!, mz = dz[e]!
                let mag = sqrt(mx * mx + my * my + mz * mz)
                if mag > 0 {
                    let cap = min(mag, temperature)
                    px[e]! += mx / mag * cap
                    py[e]! += my / mag * cap
                    pz[e]! += mz / mag * cap
                }
            }

            // Slightly slower cooling than before so the layout has
            // more time to find a clean separation between clusters.
            temperature = max(0.05, temperature * 0.985)
        }

        // Recentre on origin.
        var cx: CGFloat = 0, cy: CGFloat = 0, cz: CGFloat = 0
        for e in entities {
            cx += px[e]!; cy += py[e]!; cz += pz[e]!
        }
        cx /= CGFloat(n); cy /= CGFloat(n); cz /= CGFloat(n)

        var positions: [String: SCNVector3] = [:]
        for e in entities {
            positions[e] = SCNVector3(px[e]! - cx, py[e]! - cy, pz[e]! - cz)
        }
        return positions
    }
}

/// Tiny deterministic RNG for layout reproducibility.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { self.state = seed != 0 ? seed : 0xdeadbeef }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
    mutating func nextDouble() -> Double {
        return Double(next() &>> 11) / Double(1 &<< 53)
    }
}
