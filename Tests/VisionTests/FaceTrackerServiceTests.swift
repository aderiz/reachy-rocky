import Testing
import Foundation
import SidecarHost
import Telemetry
import RockyVision

/// End-to-end test of `FaceTrackerService` against the real synthetic sidecar.
@Suite("FaceTrackerService — synthetic")
struct FaceTrackerServiceTests {

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

    private static func makeService() async throws -> FaceTrackerService {
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
                "ROCKY_FT_DAMPER_OMEGA": "8.0",
                "ROCKY_FT_SYN_DROP_EVERY": "5",  // long window so detections flow
                "ROCKY_FT_SYN_DROP_DUR": "0.2",
                "ROCKY_FT_SYN_DROP_P": "0.0",
            ],
            readyTimeoutS: 10,
            shutdownGraceS: 2
        )
        let venv = FileManager.default.temporaryDirectory
            .appendingPathComponent("rocky-vision-test-\(UUID().uuidString)")
        let resolver = ManifestPathResolver(sidecarDir: dir, venvDir: venv)
        let bus = LogBus()
        let runtime = SidecarRuntime(manifest: manifest, resolver: resolver, logBus: bus)
        return FaceTrackerService(sidecar: runtime, logBus: bus)
    }

    actor Counters {
        var targets = 0
        var detections = 0
        var lastYaw: Double = 0
        var lastPitch: Double = 0
        func bumpT(_ y: Double, _ p: Double) { targets += 1; lastYaw = y; lastPitch = p }
        func bumpD() { detections += 1 }
        func snapshot() -> (Int, Int, Double, Double) { (targets, detections, lastYaw, lastPitch) }
    }

    @Test("service bridges target and detection streams")
    func bridgeStreams() async throws {
        let service = try await Self.makeService()
        try await service.start()
        defer { Task { await service.stop() } }

        let counters = Counters()
        let targets = service.targets
        let detections = service.detections

        let tTask = Task {
            for await t in targets {
                await counters.bumpT(t.yawRad, t.pitchRad)
            }
        }
        let dTask = Task {
            for await _ in detections {
                await counters.bumpD()
            }
        }

        try await Task.sleep(nanoseconds: 800_000_000)
        tTask.cancel()
        dTask.cancel()

        let (t, d, y, p) = await counters.snapshot()
        #expect(t > 25, "expected >25 target events in 800ms; got \(t)")
        #expect(d >= 2,  "expected >=2 detections; got \(d)")
        #expect(abs(y) + abs(p) > 0, "target should be moving")
    }

    @Test("setEnabled false succeeds")
    func setEnabledFalse() async throws {
        let service = try await Self.makeService()
        try await service.start()
        defer { Task { await service.stop() } }
        try await service.setEnabled(false)
    }
}
