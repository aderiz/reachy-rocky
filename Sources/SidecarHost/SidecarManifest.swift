import Foundation

/// Manifest describing how to launch and supervise a sidecar process.
///
/// Stored as `manifest.json` next to the sidecar's source. JSON (not TOML) so
/// `JSONDecoder` parses it without an extra dependency. Path placeholders:
/// - `{venv}` → `~/Library/Application Support/Rocky/sidecars/<name>/.venv`
/// - `{sidecar_dir}` → the directory containing the manifest.
public struct SidecarManifest: Sendable, Codable, Equatable {
    public let name: String
    public let version: String
    public let binary: String
    public let args: [String]
    public let workingDir: String
    public let env: [String: String]

    public let readyEvent: String
    public let readyTimeoutS: Double
    public let shutdownGraceS: Double
    public let restartPolicy: RestartPolicy
    public let restartMaxPerMinute: Int

    /// Per-method timeouts in seconds. The key `"*"` is the default for unlisted methods.
    public let timeouts: [String: Double]

    public enum RestartPolicy: String, Sendable, Codable, Equatable {
        case never
        case onFailure = "on_failure"
        case always
    }

    enum CodingKeys: String, CodingKey {
        case name, version, binary, args, env
        case workingDir = "working_dir"
        case readyEvent = "ready_event"
        case readyTimeoutS = "ready_timeout_s"
        case shutdownGraceS = "shutdown_grace_s"
        case restartPolicy = "restart_policy"
        case restartMaxPerMinute = "restart_max_per_minute"
        case timeouts
    }

    public init(
        name: String,
        version: String,
        binary: String,
        args: [String],
        workingDir: String,
        env: [String: String] = [:],
        readyEvent: String = "ready",
        readyTimeoutS: Double = 30,
        shutdownGraceS: Double = 5,
        restartPolicy: RestartPolicy = .onFailure,
        restartMaxPerMinute: Int = 3,
        timeouts: [String: Double] = ["*": 5]
    ) {
        self.name = name
        self.version = version
        self.binary = binary
        self.args = args
        self.workingDir = workingDir
        self.env = env
        self.readyEvent = readyEvent
        self.readyTimeoutS = readyTimeoutS
        self.shutdownGraceS = shutdownGraceS
        self.restartPolicy = restartPolicy
        self.restartMaxPerMinute = restartMaxPerMinute
        self.timeouts = timeouts
    }

    public func timeout(forMethod method: String) -> Double {
        timeouts[method] ?? timeouts["*"] ?? 5
    }
}

/// Resolves placeholders like `{venv}` and `{sidecar_dir}` against a runtime context.
public struct ManifestPathResolver: Sendable {
    public let sidecarDir: URL
    public let venvDir: URL

    public init(sidecarDir: URL, venvDir: URL) {
        self.sidecarDir = sidecarDir
        self.venvDir = venvDir
    }

    public func resolve(_ value: String) -> String {
        value
            .replacingOccurrences(of: "{venv}", with: venvDir.path(percentEncoded: false))
            .replacingOccurrences(of: "{sidecar_dir}", with: sidecarDir.path(percentEncoded: false))
    }

    public func resolve(_ values: [String]) -> [String] {
        values.map(resolve)
    }
}
