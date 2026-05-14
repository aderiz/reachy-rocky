import Foundation

/// Where the robot daemon lives. Defaults to the Wireless mDNS name; override
/// to a raw IP when mDNS isn't available (hotel/conference WiFi, etc.).
///
/// **Motion routing**: when `motionPort` is non-nil, motion calls are
/// rewritten to `http://<host>:<motionPort>/api/motion/*` instead of
/// the default `http://<host>:<port>/api/move/*`. The relay running
/// on the bot at port 8042 exposes `/api/motion/*` endpoints that
/// enforce the on-bot motion guard before forwarding to the daemon.
/// State reads (`/api/state/*`) always go to the daemon port directly
/// — they're read-only, no safety implication.
public struct RobotEndpoint: Sendable, Equatable, Hashable {
    public let host: String
    public let port: Int
    public let motionPort: Int?

    public init(
        host: String = "reachy-mini.local",
        port: Int = 8000,
        motionPort: Int? = 8042
    ) {
        self.host = host
        self.port = port
        self.motionPort = motionPort
    }

    public var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    public func wsURL(_ path: String) -> URL {
        URL(string: "ws://\(host):\(port)\(path)")!
    }

    public func apiURL(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    /// `apiURL` plus a query string. Path segments still go through
    /// `appendingPathComponent`, so the query is appended manually.
    /// The daemon's `/api/state/full` only populates `head_joints`,
    /// `body_yaw`, `antennas_position` and `passive_joints` when the
    /// matching `with_*=true` flags are set.
    public func apiURL(_ path: String, query: String) -> URL {
        var s = baseURL.appendingPathComponent(path).absoluteString
        s += s.contains("?") ? "&" : "?"
        s += query
        return URL(string: s)!
    }

    /// Returns the URL for a motion-bearing call. When `motionPort`
    /// is set, the path is rewritten:
    ///   /api/move/set_target   → :motionPort/api/motion/set_target
    ///   /api/move/goto         → :motionPort/api/motion/goto
    ///   /api/move/play/X/Y     → :motionPort/api/motion/play/X/Y
    ///   /api/move/play/Z       → :motionPort/api/motion/play/Z
    ///   /api/motor/mode        → :motionPort/api/motion/set_motor_mode
    ///   /api/move/stop_move    → :motionPort/api/motion/stop_move
    /// Anything else falls through to the daemon port unchanged.
    public func motionURL(_ originalPath: String) -> URL {
        guard let mp = motionPort else { return apiURL(originalPath) }
        let rewritten: String
        switch originalPath {
        case "/api/move/set_target":
            rewritten = "/api/motion/set_target"
        case "/api/move/goto":
            rewritten = "/api/motion/goto"
        case "/api/move/stop_move":
            rewritten = "/api/motion/stop_move"
        case "/api/motion/wake_up":
            // Already in motion-namespace — wake is an on-bot
            // orchestrated sequence that the relay owns.
            rewritten = "/api/motion/wake_up"
        default:
            if originalPath.hasPrefix("/api/move/play/") {
                let tail = String(originalPath.dropFirst("/api/move/play/".count))
                if tail.hasPrefix("recorded-move-dataset/") {
                    let dsAndMove = String(tail.dropFirst("recorded-move-dataset/".count))
                    rewritten = "/api/motion/play/\(dsAndMove)"
                } else {
                    rewritten = "/api/motion/play/\(tail)"
                }
            } else {
                return apiURL(originalPath)
            }
        }
        return URL(string: "http://\(host):\(mp)\(rewritten)")!
    }
}

public enum RobotLinkError: Error, Sendable {
    case http(status: Int, body: String)
    case transport(message: String)
    case decode(message: String)
    case offline
    case daemonNotReady
}
