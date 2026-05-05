import SwiftUI
import RockyKit

struct RootView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            DashboardView()
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
    var body: some View {
        List {
            Section("Status") {
                Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
                Label("Brain",      systemImage: "brain")
                Label("Voice",      systemImage: "waveform")
                Label("Body",       systemImage: "figure.stand")
                Label("Vision",     systemImage: "eye")
            }
            Section("Diagnostics") {
                Label("Sidecars",   systemImage: "shippingbox")
                Label("Logs",       systemImage: "doc.plaintext")
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
