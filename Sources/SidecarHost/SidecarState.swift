import Foundation

public enum SidecarState: Sendable, Equatable {
    /// Not yet started, or stopped cleanly.
    case stopped
    /// `Process.run()` was issued; waiting for the `ready` event.
    case starting
    /// Sidecar emitted its ready event and is accepting requests.
    case ready
    /// Sidecar crashed or hit an error; supervisor will retry per `restartPolicy`.
    case failing(reason: String)
    /// Hit the per-minute restart cap; supervisor is in cooldown.
    case circuitOpen(cooldownUntil: Date)
}

public enum SidecarError: Error, Sendable {
    case alreadyRunning
    case notReady
    case readyTimeout
    case crashed(reason: String)
    case methodTimeout(method: String, after: Double)
    case decode(message: String)
    case process(message: String)
    case supervisorClosed
}
