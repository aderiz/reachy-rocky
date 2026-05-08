import SwiftUI

/// Inspector — the engineering drawer.
///
/// Per `docs/concepts/cockpit-design.md` §3.4, the inspector is a
/// trailing `.inspector` panel summoned from the toolbar. It holds
/// every existing diagnostic surface, just relocated from the sidebar:
///
///   - Health   — today's StatusView. Wave 4 reorganises by severity.
///   - Activity — the moment feed (placeholder until Wave 4 lands the
///                actual MomentFeed actor; for now points to LogsView).
///   - Memory   — drawer count, recall toggle, recent drawers (placeholder
///                pointing at the existing Settings memory section until
///                Wave 4 builds the dedicated tab).
///   - Motion   — today's MotionCard.
///   - Vision   — today's VisionCard.
///   - Raw      — today's LogsView (the firehose, preserved verbatim).
///
/// Wave 1 deliberately re-exports existing views without redesign; the
/// goal is to free the cockpit from these surfaces, not to redesign
/// them. Subsequent waves polish each tab.
struct InspectorView: View {
    @State private var selection: Tab = .health

    enum Tab: Hashable, CaseIterable, Identifiable {
        case health, activity, memory, motion, vision, raw
        var id: Self { self }
        var label: String {
            switch self {
            case .health:   "Health"
            case .activity: "Activity"
            case .memory:   "Memory"
            case .motion:   "Motion"
            case .vision:   "Vision"
            case .raw:      "Raw"
            }
        }
        var icon: String {
            switch self {
            case .health:   "heart.text.square"
            case .activity: "list.bullet.rectangle"
            case .memory:   "brain"
            case .motion:   "figure.stand"
            case .vision:   "eye"
            case .raw:      "doc.plaintext"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 320)
    }

    private var picker: some View {
        Picker("", selection: $selection) {
            ForEach(Tab.allCases) { tab in
                Image(systemName: tab.icon)
                    .help(tab.label)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .health:   StatusView()
        case .activity: ActivityTab()
        case .memory:   MemoryTab()
        case .motion:   MotionCard()
        case .vision:   VisionCard()
        case .raw:      LogsView()
        }
    }
}
