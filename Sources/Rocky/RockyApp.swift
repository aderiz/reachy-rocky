import SwiftUI
import AppKit
import RobotLink
import RockyKit
import SidecarHost
import Telemetry

@main
struct RockyApp: App {
    @State private var services = AppServices()

    init() {
        // Without this, a SwiftPM executable launched directly (e.g. ⌘R
        // in Xcode on Package.swift, or `swift run`) defaults to the
        // `.prohibited` activation policy because there's no Info.plist
        // bundle to define one. In that mode AppKit doesn't make the
        // SwiftUI window key, and TextFields silently refuse keyboard
        // input. `build/Rocky.app` (from scripts/build-app.sh) ships an
        // Info.plist so this isn't strictly required for the bundled
        // app, but doing it unconditionally lets either launch path work
        // identically — useful while iterating in Xcode's debugger.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Install the ⌥⌘R "summon Rocky" hotkey — works from anywhere
        // on the system. See docs/concepts/cockpit-design.md §3.5.
        HotkeyMonitor.shared.install()
    }

    var body: some Scene {
        WindowGroup("Rocky") {
            RootView()
                .environment(services)
                .frame(minWidth: 920, minHeight: 600)
                .task { await services.start() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Surface the summon shortcut in the standard Help menu so
            // users discover it. The hotkey itself is installed globally
            // by HotkeyMonitor; the menu command also fires when the app
            // is foregrounded.
            CommandGroup(after: .windowArrangement) {
                Button("Show Rocky") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.title == "Rocky" })?
                        .makeKeyAndOrderFront(nil)
                }
                .keyboardShortcut("r", modifiers: [.option, .command])
            }
            // Help menu: re-trigger the first-run flow on demand. The
            // overlay shows whenever firstRunCompleted is false and
            // disappears the moment it's set true; toggling here is
            // the recovery path for "I want to revisit setup."
            CommandGroup(replacing: .help) {
                Button("Show First Run") {
                    services.settings.firstRunCompleted = false
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.title == "Rocky" })?
                        .makeKeyAndOrderFront(nil)
                }
            }
        }

        // Per the cockpit design (`docs/concepts/cockpit-design.md`),
        // Settings lives in a real macOS Settings scene, not as a tab in
        // the main window. ⌘, opens it from anywhere; the Settings entry
        // disappears from the sidebar in a follow-up step.
        //
        // Wave 1 ships the scene wrapping the existing SettingsView
        // verbatim — no content changes. Wave 5 splits it into six
        // tabs (Robot, Brain, Voice, Memory, Faces, Persona).
        Settings {
            SettingsView()
                .environment(services)
                .frame(minWidth: 720, minHeight: 540)
        }

        MenuBarExtra {
            MenuBarStatusView()
                .environment(services)
        } label: {
            MenuBarLabel()
                .environment(services)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @Environment(AppServices.self) private var services
    var body: some View {
        // Drive the menu bar icon from the finer-grained `rockyState`
        // (per `docs/concepts/cockpit-design.md` §3.5) rather than the
        // coarser BotMode, so the icon distinguishes listening / thinking
        // / speaking / sleeping / etc. The glyph table is the design
        // doc's table; animations are only repeating for active states.
        let symbol: String = switch services.rockyState {
        case .sleeping:    "moon.zzz"
        case .waking:      "sun.max"
        case .idle:        "circle.dotted"
        case .tracking:    "eye"
        case .listening:   "ear"
        case .thinking:    "brain"
        case .speaking:    "waveform"
        case .error:       "exclamationmark.triangle.fill"
        }
        Image(systemName: symbol)
    }
}
