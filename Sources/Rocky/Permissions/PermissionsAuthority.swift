import Foundation
import Observation
import AVFoundation
import CoreLocation
import EventKit
import Speech
import AppKit

/// Single source of truth for the four TCC permissions Rocky uses.
/// Every UI surface (FirstRunOverlay, Settings → Permissions,
/// StatusView Health rows) and every tool guard (LocationProvider,
/// CalendarTool) consults this class instead of reading the OS APIs
/// directly. That kills the divergence class of bugs where the
/// onboarding overlay says "granted" but the tool says "denied", or
/// where two surfaces map `.writeOnly` differently.
///
/// State is published via `@Observable` so SwiftUI bindings re-render
/// automatically. Each read calls the OS API freshly (no internal
/// cache); the `refresh()` call is provided for explicit re-reads
/// (e.g. on `NSApplication.didBecomeActive`).
///
/// Speech specifically routes through `SFSpeechRecognizer.requestAuthorization`
/// rather than the cached `authorizationStatus()` — Apple's per-process
/// cache for the latter does not invalidate when the user toggles in
/// System Settings, which was a documented source of "granted in
/// macOS but Rocky says denied" reports.
@Observable
@MainActor
final class PermissionsAuthority {

    /// Status enum matching what the OS actually surfaces. Three-state
    /// (granted/denied/unknown) collapses too much information — the
    /// `.limited` case in particular is essential for Calendar's
    /// `.writeOnly` (macOS Settings labels this "Add Events Only", and
    /// telling the user "Denied" was misleading them).
    enum Status: Sendable, Equatable {
        case granted
        /// Partially granted — Rocky has *some* access, but not what
        /// it needs. Calendar `.writeOnly` is the canonical case.
        case limited(reason: String)
        case denied
        case notDetermined
        /// Disallowed by parental controls / MDM. User cannot change
        /// this in System Settings without admin intervention.
        case restricted

        var isUsableByRocky: Bool { self == .granted }
        var isExplicitlyResolved: Bool {
            switch self {
            case .denied, .restricted, .granted: return true
            case .limited: return true
            case .notDetermined: return false
            }
        }
    }

    /// Logical permissions Rocky needs. Mapped 1:1 to system Privacy &
    /// Security panes; the `settingsAnchor` deep-links to the right
    /// pane. Mic is conditional (only required for Mac mic path).
    enum Permission: String, CaseIterable, Sendable {
        case microphone
        case speechRecognition
        case calendar
        case location

        var settingsAnchor: String {
            switch self {
            case .microphone:        return "Privacy_Microphone"
            case .speechRecognition: return "Privacy_SpeechRecognition"
            case .calendar:          return "Privacy_Calendars"
            case .location:          return "Privacy_LocationServices"
            }
        }

        var displayName: String {
            switch self {
            case .microphone:        return "Microphone"
            case .speechRecognition: return "Speech recognition"
            case .calendar:          return "Calendar"
            case .location:          return "Location"
            }
        }

        var rationale: String {
            switch self {
            case .microphone:
                return "So Rocky can hear you say his name."
            case .speechRecognition:
                return "So your words become text Rocky can act on."
            case .calendar:
                return "So Rocky can answer \"what's on tomorrow?\" without guessing."
            case .location:
                return "So \"what's the weather?\" works without naming the city."
            }
        }
    }

    // MARK: - Published state

    private(set) var microphone: Status = .notDetermined
    private(set) var speechRecognition: Status = .notDetermined
    private(set) var calendar: Status = .notDetermined
    private(set) var location: Status = .notDetermined

    // MARK: - Init / refresh

    init() {
        refresh()
        // Pick up changes the user makes in System Settings without
        // restarting Rocky. macOS fires `didBecomeActive` when the
        // user ⌘-tabs back from Settings.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Re-read every permission's current OS state. Cheap — just four
    /// class-method calls. Call from `didBecomeActive`, after a
    /// request completes, or from anywhere a refresh is needed.
    func refresh() {
        microphone        = Self.readMicrophone()
        speechRecognition = Self.readSpeechRecognition()
        calendar          = Self.readCalendar()
        location          = Self.readLocation()
    }

    func current(_ permission: Permission) -> Status {
        switch permission {
        case .microphone:        return microphone
        case .speechRecognition: return speechRecognition
        case .calendar:          return calendar
        case .location:          return location
        }
    }

    // MARK: - Read helpers (always fresh)

    private static func readMicrophone() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:                       return .granted
        case .denied:                           return .denied
        case .restricted:                       return .restricted
        case .notDetermined:                    return .notDetermined
        @unknown default:                       return .notDetermined
        }
    }

    private static func readSpeechRecognition() -> Status {
        // `SFSpeechRecognizer.authorizationStatus()` reads from a
        // per-process cache that doesn't invalidate when the user
        // toggles the permission in System Settings. We *still* call
        // it for the synchronous read, but the canonical fresh-read
        // path is `request(.speechRecognition)`, which routes through
        // `SFSpeechRecognizer.requestAuthorization` (no prompt once
        // determined, but does pick up out-of-process changes).
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:                       return .granted
        case .denied:                           return .denied
        case .restricted:                       return .restricted
        case .notDetermined:                    return .notDetermined
        @unknown default:                       return .notDetermined
        }
    }

    private static func readCalendar() -> Status {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:          return .granted
        case .writeOnly:
            return .limited(
                reason: "Add Events Only — Rocky needs Full Access to read your schedule."
            )
        case .denied:                           return .denied
        case .restricted:                       return .restricted
        case .notDetermined:                    return .notDetermined
        @unknown default:                       return .notDetermined
        }
    }

    private static func readLocation() -> Status {
        // CLAuthorizationStatus on macOS Sequoia can return raw values
        // the named cases don't cover (e.g. `.authorizedWhenInUse`'s
        // raw 4 isn't compilable on macOS but the runtime can still
        // emit it). Match by exclusion — anything not explicitly
        // bad is treated as granted.
        switch LocationProvider.shared.authorizationStatus {
        case .denied:                           return .denied
        case .restricted:                       return .restricted
        case .notDetermined:                    return .notDetermined
        default:                                return .granted
        }
    }

    // MARK: - Request

    /// Show the system prompt if status is `.notDetermined`. For
    /// already-resolved permissions, this is effectively a no-op
    /// that re-reads the current status. After completion, the
    /// authority's published state is updated.
    func request(_ permission: Permission) async -> Status {
        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)

        case .speechRecognition:
            // Use the closure-based API directly. This is the only
            // SFSpeechRecognizer call that actually reflects the
            // current OS state — `authorizationStatus()` is cached
            // per-process and doesn't pick up grants from System
            // Settings.
            _ = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status)
                }
            }

        case .calendar:
            do {
                let store = EKEventStore()
                _ = try await store.requestFullAccessToEvents()
            } catch {
                // Fall through to refresh — the read will catch the
                // resolved state regardless of why this threw.
            }

        case .location:
            _ = await LocationProvider.shared.requestAuthorization()
        }
        refresh()
        return current(permission)
    }

    // MARK: - Open System Settings

    /// Deep-link to the right Privacy & Security pane. Used when the
    /// user has explicitly denied something — macOS won't re-prompt
    /// in-process, so System Settings is the only path back.
    func openSystemSettings(for permission: Permission) {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)"
        )!
        NSWorkspace.shared.open(url)
    }
}
