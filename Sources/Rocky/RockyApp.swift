import SwiftUI
import AppKit
import RobotLink
import RockyKit
import SidecarHost
import Telemetry

@main
struct RockyApp: App {
    @State private var services = AppServices()
    @NSApplicationDelegateAdaptor(SafetyDelegate.self) private var delegate

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
        // Single-instance guard — runs BEFORE any AppServices wiring
        // so we can't possibly start a second TargetStreamer / face
        // tracker pointing at the same robot. We hit this on
        // 2026-05-08: an Xcode Debug build and a freshly-launched
        // build/Rocky.app were both POSTing to /api/move/set_target
        // at 50 Hz. The daemon couldn't pick a winner and the head
        // moved aggressively. Fail-closed: refuse to start, prompt
        // the user, terminate the peer if they confirm.
        Self.enforceSingleInstance()
        // Install the ⌥⌘R "summon Rocky" hotkey — works from anywhere
        // on the system. See docs/concepts/cockpit-design.md §3.5.
        HotkeyMonitor.shared.install()
    }

    /// Refuse to start if another copy of Rocky is already running.
    /// Bundle ID match is the source of truth — peers from `swift run`
    /// (no bundle ID) are skipped, but those don't ship a real
    /// TargetStreamer-and-sidecars setup either. The bundled
    /// `build/Rocky.app` is what actually drives the robot, so that's
    /// what the guard cares about.
    private static func enforceSingleInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current.processIdentifier
        let peers = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        guard !peers.isEmpty else { return }

        let pids = peers.map { String($0.processIdentifier) }
                       .joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Another Rocky is already running"
        alert.informativeText = """
        Two copies of Rocky writing to the same robot send racing \
        motion commands at 50 Hz each, which causes the head to move \
        unpredictably. Only one Rocky is allowed at a time.

        Other instance: PID \(pids)
        """
        alert.addButton(withTitle: "Quit Other & Continue")
        alert.addButton(withTitle: "Quit This Rocky")
        alert.alertStyle = .critical

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            // User picked "Quit This Rocky" — exit before SwiftUI
            // brings up a window. Use exit(0) rather than NSApp
            // termination because NSApp.run() hasn't started yet.
            exit(0)
        }

        // Terminate peers gracefully, then force-kill any holdouts.
        for peer in peers { peer.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let still = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me }
            if still.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let stragglers = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        for peer in stragglers { peer.forceTerminate() }
    }

    var body: some Scene {
        WindowGroup("Rocky") {
            RootView()
                .environment(services)
                .frame(minWidth: 920, minHeight: 600)
                .task {
                    delegate.services = services
                    await services.start()
                }
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
            // Surface the command palette in the Edit menu (after
            // Find) so users discover ⌘K via the menu bar without
            // needing the design doc to find it. Both the menu item
            // and the keyboard shortcut flip the same observable on
            // AppServices, which the cockpit window subscribes to via
            // a binding-driven .sheet.
            CommandGroup(after: .textEditing) {
                Button("Command Palette…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.title == "Rocky" })?
                        .makeKeyAndOrderFront(nil)
                    services.commandPaletteOpen = true
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
        }

        // Settings as a real `Window` scene, not the macOS
        // `Settings { }` scene. The latter is designed around a
        // TabView with Form sections — its custom window chrome
        // suppresses the title bar background and breaks
        // NavigationSplitView's auto-laid sidebar toggle. A plain
        // Window lets NavigationSplitView own the title bar
        // (traffic-lights + sidebar-toggle + section title align on
        // one row, just like System Settings does on macOS 14+).
        //
        // ⌘, is wired via a custom Button command below that uses
        // `openWindow` to materialise this scene by id.
        Window("Rocky Settings", id: SettingsView.windowID) {
            SettingsView()
                .environment(services)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsMenuButton()
            }
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

/// Defers `NSApp.terminate(_:)` until `AppServices.safeShutdown()`
/// finishes — stopping the 50 Hz target streamer and disabling the
/// daemon's motor controller before the process actually exits. We
/// hit a hardware-safety incident on 2026-05-08 where two Rockys
/// quitting in quick succession left the bot oscillating; this
/// closes the loop. NSApplicationMain only invokes the delegate
/// once and waits up to ~5 s for `reply(toApplicationShouldTerminate:)`.
@MainActor
final class SafetyDelegate: NSObject, NSApplicationDelegate {
    weak var services: AppServices?

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let services else { return .terminateNow }
        Task { @MainActor in
            await services.safeShutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
