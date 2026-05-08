import Foundation

/// Where the robot daemon lives. Defaults to the Wireless mDNS name; override
/// to a raw IP when mDNS isn't available (hotel/conference WiFi, etc.).
public struct RobotEndpoint: Sendable, Equatable, Hashable {
    public let host: String
    public let port: Int

    public init(host: String = "reachy-mini.local", port: Int = 8000) {
        self.host = host
        self.port = port
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
}

public enum RobotLinkError: Error, Sendable {
    case http(status: Int, body: String)
    case transport(message: String)
    case decode(message: String)
    case offline
    case daemonNotReady
}
