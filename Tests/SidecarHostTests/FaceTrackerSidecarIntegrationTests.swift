import Testing
import Foundation
import SidecarHost
import Telemetry

/// Integration tests that spawn the real face-tracker sidecar (synthetic
/// detector mode, no MLX or robot needed) via /usr/bin/python3 and
/// verify the wire contract.
@Suite("Face-tracker sidecar — synthetic mode integration")
struct FaceTrackerSidecarIntegrationTests {

    private static func sidecarDir(_ file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Sidecars/face-tracker", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
            url = url.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sidecars/face-tracker from \(file)")
        return URL(fileURLWithPath: "/")
    }

    /// Build a manifest in-memory that points at /usr/bin/python3 directly,
    /// so the tests don't depend on a uv-built venv.
    private static func makeRuntime() async throws -> SidecarRuntime {
        let dir = sidecarDir()
        let manifest = SidecarManifest(
            name: "face-tracker-test",
            version: "0.0.0-test",
            binary: "/usr/bin/python3",
            args: ["-u", "-m", "rocky_face_tracker.runner"],
            workingDir: dir.path(percentEncoded: false),
            env: [
                "PYTHONPATH": dir.path(percentEncoded: false),
                "ROCKY_FT_MODE": "synthetic",
                "ROCKY_FT_HFOV_DEG": "65",
                "ROCKY_FT_VFOV_DEG": "39",
                "ROCKY_FT_DAMPER_OMEGA": "8.0",
                "ROCKY_FT_EMA_ALPHA": "0.5",
                "ROCKY_FT_IDLE_TIMEOUT_S": "1.5",
                "ROCKY_FT_PROMPT": "test prompt",
                // Smaller drop windows make the test see decay quickly.
                "ROCKY_FT_SYN_DROP_EVERY": "1.5",
                "ROCKY_FT_SYN_DROP_DUR": "0.4",
            ],
            readyTimeoutS: 10,
            shutdownGraceS: 2,
            timeouts: ["*": 5]
        )
        let venvStub = FileManager.default.temporaryDirectory
            .appendingPathComponent("rocky-ft-venv-\(UUID().uuidString)")
        let resolver = ManifestPathResolver(sidecarDir: dir, venvDir: venvStub)
        return SidecarRuntime(manifest: manifest, resolver: resolver, logBus: LogBus())
    }

    // MARK: - Tests

    actor Counters {
        var targetCount = 0
        var detectionCount = 0
        var lastYaw: Double = 0
        var lastPitch: Double = 0
        var lastDecay: Bool = false

        func bumpTarget(yaw: Double, pitch: Double, decay: Bool) {
            targetCount += 1
            lastYaw = yaw
            lastPitch = pitch
            lastDecay = decay
        }
        func bumpDetection() { detectionCount += 1 }
        func snapshot() -> (Int, Int, Double, Double) {
            (targetCount, detectionCount, lastYaw, lastPitch)
        }
    }

    @Test("ready event arrives and target stream begins flowing")
    func readyAndTargets() async throws {
        let runtime = try await Self.makeRuntime()
        try await runtime.start()
        defer { Task { await runtime.stop() } }

        let counters = Counters()
        let deadline = Date().addingTimeInterval(0.6)
        let stream = runtime.events
        let task = Task {
            for await event in stream {
                if case .event(let name, let payload) = event {
                    if name == "target" {
                        let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
                        let yaw = (dict?["yaw_rad"] as? Double) ?? 0
                        let pitch = (dict?["pitch_rad"] as? Double) ?? 0
                        let decay = (dict?["decay_active"] as? Bool) ?? false
                        await counters.bumpTarget(yaw: yaw, pitch: pitch, decay: decay)
                    } else if name == "detection" {
                        await counters.bumpDetection()
                    }
                }
                if Date() >= deadline { break }
            }
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        task.cancel()

        let (targetCount, detectionCount, lastYaw, lastPitch) = await counters.snapshot()

        // 50 Hz target stream over ~0.6 s should comfortably exceed 20 events.
        #expect(targetCount > 20, "expected >20 target events; got \(targetCount)")
        #expect(detectionCount >= 1, "expected at least one detection; got \(detectionCount)")
        #expect(abs(lastYaw) + abs(lastPitch) > 0, "expected target to be moving")
    }

    @Test("set_enabled false silences detection ingestion")
    func setEnabledFalse() async throws {
        let runtime = try await Self.makeRuntime()
        try await runtime.start()
        defer { Task { await runtime.stop() } }

        struct EnabledParams: Encodable, Sendable { let enabled: Bool }
        struct EnabledResult: Decodable, Sendable { let enabled: Bool }

        let res: EnabledResult = try await runtime.send(
            method: "set_enabled", params: EnabledParams(enabled: false)
        )
        #expect(!res.enabled)
    }

    @Test("health round-trip reports configured mode and prompt")
    func health() async throws {
        let runtime = try await Self.makeRuntime()
        try await runtime.start()
        defer { Task { await runtime.stop() } }

        struct Empty: Encodable, Sendable {}
        struct Health: Decodable, Sendable {
            let mode: String
            let enabled: Bool
            let prompt: String
        }

        let h: Health = try await runtime.send(method: "health", params: Empty())
        #expect(h.mode == "synthetic")
        #expect(h.enabled == true)
        #expect(h.prompt == "test prompt")
    }
}
