import Foundation
import CoreLocation

/// MainActor-pinned wrapper around CLLocationManager. Two callsites:
/// the onboarding "Grant access" step (asks once during setup) and
/// `WeatherTool` (one-shot fetch when the LLM doesn't know which
/// city the user means). A single shared instance keeps the manager
/// alive between calls so iOS-style "rapid back-to-back requests
/// confuse the system" issues don't show up.
///
/// The macOS API is delegate-based; we wrap the one-shot
/// `requestLocation()` flow in a continuation so callers see a
/// plain async function.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    /// Live continuation for an in-flight `currentLocation()` call.
    /// CLLocationManager only services one request at a time per
    /// manager instance; multiple concurrent callers are serialized
    /// here by failing the second with `.busy` rather than racing.
    private var continuation: CheckedContinuation<CLLocation, Error>?

    private override init() {
        super.init()
        manager.delegate = self
        // City-block accuracy is plenty for "what's the weather here"
        // and avoids spinning up GPS/WiFi triangulation at full power.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    /// Show the system "allow Rocky to use your location" dialog if
    /// the status is `notDetermined`. Resolves once the user picks
    /// or times out after 8s — without a bundle ID + Info.plist
    /// usage description, macOS silently no-ops `requestWhenInUseAuthorization`
    /// and the delegate never fires, so the timeout is the only way
    /// to avoid leaking the continuation.
    func requestAuthorization() async -> CLAuthorizationStatus {
        if manager.authorizationStatus != .notDetermined {
            return manager.authorizationStatus
        }
        // Defensive guard for the "ran without a bundle" case. The
        // app needs `Bundle.main.bundleIdentifier` non-nil + the
        // location usage description in Info.plist for the system
        // dialog to appear; both ship via scripts/build-app.sh.
        if Bundle.main.bundleIdentifier == nil {
            return manager.authorizationStatus
        }
        // Reject overlapping requests rather than overwriting the
        // pending continuation — the previous async caller would
        // leak forever.
        if authPending != nil {
            return manager.authorizationStatus
        }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            guard let self, let cont = self.authPending else { return }
            self.authPending = nil
            cont.resume(returning: self.manager.authorizationStatus)
        }
        defer { timeoutTask.cancel() }
        return await withCheckedContinuation { cont in
            authPending = cont
            manager.requestWhenInUseAuthorization()
        }
    }

    /// One-shot location fetch. Returns the most recent fix or
    /// throws if denied / restricted / no signal. Default 6s timeout
    /// since the WeatherTool is in-line in a tool call and the user
    /// is waiting on a reply.
    func currentLocation(timeout: TimeInterval = 6) async throws -> CLLocation {
        // Inverted check — fail only on EXPLICITLY bad states.
        // CLAuthorizationStatus on macOS Sequoia can return raw
        // values that don't map cleanly to the named cases the
        // Swift overlay exposes (`.authorizedWhenInUse` is marked
        // unavailable on macOS but the runtime can still return
        // its raw value 4 from the OS layer). Matching on the bad
        // states explicitly avoids "we got authorization but the
        // tool says denied" footguns.
        switch authorizationStatus {
        case .notDetermined, .denied, .restricted:
            NSLog("Rocky location: refusing with status raw=\(authorizationStatus.rawValue)")
            throw LocationError.notAuthorized(authorizationStatus)
        default:
            break
        }
        if continuation != nil {
            throw LocationError.busy
        }

        // Schedule a timeout task that fails the in-flight continuation
        // if CLLocationManager doesn't fire a delegate callback in time.
        // We capture the continuation through `self.continuation` so the
        // delegate methods race against the timer for the same slot.
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(timeout * 1_000_000_000)
            )
            guard let self, let cont = self.continuation else { return }
            self.continuation = nil
            cont.resume(throwing: LocationError.timeout)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.manager.requestLocation()
        }
    }

    // MARK: - Delegate

    private var authPending: CheckedContinuation<CLAuthorizationStatus, Never>?

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            // Read the status off the main-actor instance instead of
            // touching the delegate-callback `manager` parameter,
            // which the concurrency checker can't prove is safe to
            // hop across the actor boundary.
            self.authPending?.resume(returning: self.manager.authorizationStatus)
            self.authPending = nil
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor in
            if let loc = locations.last {
                self.continuation?.resume(returning: loc)
                self.continuation = nil
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }
}

enum LocationError: Error, CustomStringConvertible {
    case notAuthorized(CLAuthorizationStatus)
    case timeout
    case busy
    case cancelled

    var description: String {
        switch self {
        case .notAuthorized(let status):
            return "Location access not granted (status raw=\(status.rawValue)). Open System Settings → Privacy & Security → Location Services and enable Rocky."
        case .timeout: return "Location fix timed out."
        case .busy:    return "Another location request is already in flight."
        case .cancelled: return "Location request cancelled."
        }
    }
}
