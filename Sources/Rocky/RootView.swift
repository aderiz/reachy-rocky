import SwiftUI
import RockyKit

struct RootView: View {
    @Environment(AppServices.self) private var services
    @State private var selection: SidebarItem = .dashboard

    enum SidebarItem: Hashable, CaseIterable, Identifiable {
        case dashboard, status, logs, settings
        var id: Self { self }
        var label: String {
            switch self {
            case .dashboard: "Dashboard"
            case .status:    "Status"
            case .logs:      "Logs"
            case .settings:  "Settings"
            }
        }
        var icon: String {
            switch self {
            case .dashboard: "rectangle.3.group"
            case .status:    "checkmark.shield"
            case .logs:      "doc.plaintext"
            case .settings:  "gear"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch selection {
            case .dashboard: DashboardView()
            case .status:    StatusView()
            case .logs:      LogsView()
            case .settings:  SettingsView()
            }
        }
        .navigationTitle("Rocky")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ConnectionBadge(reachability: services.daemonReachability)
            }
        }
    }
}

private struct SidebarView: View {
    @Binding var selection: RootView.SidebarItem

    var body: some View {
        List(RootView.SidebarItem.allCases, selection: $selection) { item in
            NavigationLink(value: item) {
                Label(item.label, systemImage: item.icon)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct DashboardView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeroCard()
                BrainCard()
                VoiceCard()
                MotionCard()
                VisionCard()
            }
            .padding(20)
        }
    }
}

private struct ConnectionBadge: View {
    let reachability: AppServices.Reachability

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch reachability {
        case .unknown:  .gray
        case .online:   .green
        case .offline:  .red
        }
    }

    private var label: String {
        switch reachability {
        case .unknown:           "checking…"
        case .online:            "online"
        case .offline(let why):  "offline · \(why)"
        }
    }
}
