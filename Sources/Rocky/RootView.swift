import SwiftUI
import RockyKit

struct RootView: View {
    @Environment(AppServices.self) private var services
    @State private var selection: SidebarItem = .cockpit

    enum SidebarItem: Hashable, CaseIterable, Identifiable {
        case cockpit, dashboard, status, logs, settings
        var id: Self { self }
        var label: String {
            switch self {
            case .cockpit:   "Cockpit"
            case .dashboard: "Dashboard"
            case .status:    "Status"
            case .logs:      "Logs"
            case .settings:  "Settings"
            }
        }
        var icon: String {
            switch self {
            case .cockpit:   "airplane"
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
            ZStack {
                BackgroundGradient().ignoresSafeArea()
                Group {
                    switch selection {
                    case .cockpit:   CockpitView()
                    case .dashboard: DashboardView()
                    case .status:    StatusView()
                    case .logs:      LogsView()
                    case .settings:  SettingsView()
                    }
                }
            }
        }
        .navigationTitle("")
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

private struct BackgroundGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.05, blue: 0.07),
                Color(red: 0.08, green: 0.09, blue: 0.13),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct DashboardView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DashboardHeader()
                HeroCard()
                BrainCard()
                VoiceCard()
                MotionCard()
                VisionCard()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 980, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct DashboardHeader: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rocky")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Your virtual coworker")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            connectionBadge
            modelBadge
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch services.daemonReachability {
        case .unknown:
            StatusPill(text: "robot · checking",
                       tint: .secondary, systemImage: "antenna.radiowaves.left.and.right")
        case .online:
            StatusPill(text: "robot · online",
                       tint: .green, systemImage: "antenna.radiowaves.left.and.right")
        case .offline(let reason):
            StatusPill(text: "robot · offline",
                       tint: .red, systemImage: "antenna.radiowaves.left.and.right.slash")
                .help(reason)
        }
    }

    @ViewBuilder
    private var modelBadge: some View {
        switch services.llmStatus {
        case .unknown:
            StatusPill(text: "brain · checking",
                       tint: .secondary, systemImage: "brain")
        case .online(let model):
            StatusPill(text: "brain · \(model)",
                       tint: .accentColor, systemImage: "brain")
        case .offline:
            StatusPill(text: "brain · offline",
                       tint: .red, systemImage: "brain")
        }
    }
}
