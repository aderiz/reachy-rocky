import AppKit
import SwiftUI

/// `⌥⌘R` — summon Rocky from anywhere.
///
/// Per `docs/concepts/cockpit-design.md` §3.5, the persistent surface is
/// the menu bar popover. SwiftUI's `MenuBarExtra` doesn't expose a
/// programmatic-open API though, so the global hotkey takes a slightly
/// looser path: it brings the main Rocky window to the front (or opens
/// it if all windows have been closed). The user can then either work
/// in the cockpit or click the menu-bar icon themselves to get the
/// popover.
///
/// Two observers are installed:
///
/// - **Local** (`addLocalMonitorForEvents`) — fires when the app is
///   already foregrounded. Returns `nil` to consume the keystroke so it
///   doesn't double-fire as a regular ⌘ shortcut.
/// - **Global** (`addGlobalMonitorForEvents`) — fires when *another* app
///   is foregrounded. Read-only by macOS design; we can't prevent it
///   reaching the focused app, so we just respond.
///
/// Combined, ⌥⌘R works from anywhere on the system. No accessibility
/// permissions required (unlike `CGEventTap`), and no Carbon-era
/// `RegisterEventHotKey` boilerplate.
@MainActor
final class HotkeyMonitor {
    private var localMonitor: Any?
    private var globalMonitor: Any?

    static let shared = HotkeyMonitor()
    private init() {}

    /// Wire up the hotkey. Idempotent — repeated calls leave at most
    /// one of each monitor installed.
    func install() {
        // Tear down any prior installation (e.g. across `applySettings`
        // re-runs) so we don't end up with duplicates after a hot reload.
        uninstall()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, Self.matchesSummonShortcut(event) else { return event }
            self.summonRocky()
            return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, Self.matchesSummonShortcut(event) else { return }
            self.summonRocky()
        }
    }

    func uninstall() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    /// `⌥⌘R` — option + command, no other modifiers, with `r` as the
    /// non-modifier character. Uses `charactersIgnoringModifiers` so a
    /// remapped layout (e.g. Dvorak) still works the same way.
    private static func matchesSummonShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == [.option, .command] else { return false }
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return chars == "r"
    }

    /// Bring Rocky to the front. If a `WindowGroup` window already
    /// exists, make it key. Otherwise activate the app — SwiftUI will
    /// show a window from `WindowGroup` automatically when the activation
    /// pulls focus to the application.
    private func summonRocky() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Rocky" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
