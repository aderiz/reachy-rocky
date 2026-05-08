import Foundation
import SidecarHost
import Telemetry

/// Pulls audio from the Reachy Mini onboard mic array via the `robot-mic`
/// sidecar (which runs `reachy_mini` SDK over WebRTC) and writes Float32
/// samples into a shared `AudioRingBuffer`. `VoiceCoordinator` reads from
/// the same buffer, so VAD/STT see robot audio identically to Mac audio.
public actor RobotMicService {
    public let buffer: AudioRingBuffer
    private let sidecar: any Sidecar
    private let logBus: LogBus
    private var pumpTask: Task<Void, Never>?
    public private(set) var isRunning: Bool = false
    public private(set) var lastRMS: Float = 0
    public private(set) var lastSampleRate: Int = 16_000
    public private(set) var lastDoaRad: Double?
    public private(set) var lastDoaIsSpeech: Bool = false
    /// First `.state(.ready)` corresponds to the initial start in
    /// `start()` — we already issued `start_recording` synchronously
    /// for that one. Subsequent `.ready` transitions mean the
    /// supervisor respawned the sidecar (e.g. after the runner's
    /// stall watchdog fired), and the new process is sitting idle
    /// waiting for `start_recording` to be re-issued.
    private var seenInitialReady: Bool = false

    public init(buffer: AudioRingBuffer, sidecar: any Sidecar, logBus: LogBus) {
        self.buffer = buffer
        self.sidecar = sidecar
        self.logBus = logBus
    }

    public func start() async throws {
        // The Python sidecar process is started ONCE; subsequent
        // listen-toggle cycles just flip the recording state via RPC
        // and don't re-spawn the process. `SidecarRuntime.start()`
        // throws `alreadyRunning` if the process is already in
        // `.ready` / `.starting` — that's expected here, not an error.
        do {
            try await sidecar.start()
        } catch SidecarError.alreadyRunning {
            // sidecar already up — continue to start_recording.
        }

        try await issueStartRecording()

        // Pump unsolicited events into the ring buffer.
        let events = sidecar.events
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.handleSidecarEvent(event)
                if Task.isCancelled { break }
            }
        }
        isRunning = true
    }

    private func issueStartRecording() async throws {
        struct Empty: Encodable, Sendable {}
        struct R: Decodable, Sendable { let recording: Bool }
        let _: R = try await sidecar.send(method: "start_recording", params: Empty())
    }

    private func handleSidecarEvent(_ event: SidecarOutboundEvent) async {
        switch event {
        case .event(let name, let payload):
            await handleEvent(name: name, payload: payload)
        case .state(let s):
            // Resume recording on supervisor-driven restarts. The
            // Python `start_recording` is idempotent (it no-ops if
            // already recording), so this is safe even if a
            // transient `.ready` comes through that wasn't a restart.
            if s == .ready {
                if !seenInitialReady {
                    seenInitialReady = true
                } else if isRunning {
                    do {
                        try await issueStartRecording()
                        await logBus.publish(.sidecarLog(
                            sidecar: "robot-mic",
                            level: .info,
                            message: "resumed recording after sidecar restart",
                            fields: [:]
                        ))
                    } catch {
                        await logBus.publish(.error(
                            scope: "robot-mic",
                            message: "restart resume failed: \(error)",
                            recoverable: true
                        ))
                    }
                }
            }
        case .log:
            break
        }
    }

    public func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        isRunning = false
        struct Empty: Encodable, Sendable {}
        struct R: Decodable, Sendable { let recording: Bool }
        do {
            let _: R = try await sidecar.send(method: "stop_recording", params: Empty())
        } catch {
            await logBus.publish(.error(scope: "robot-mic", message: "\(error)", recoverable: true))
        }
    }

    private func handleEvent(name: String, payload: Data) async {
        switch name {
        case "audio":
            guard
                let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                let b64 = dict["samples_b64"] as? String,
                let pcm = Data(base64Encoded: b64)
            else { return }
            let sr = (dict["sample_rate"] as? Int) ?? 16_000
            lastSampleRate = sr
            if let rms = dict["rms"] as? Double { lastRMS = Float(rms) }

            // PCM16 LE -> Float32 normalized to [-1, +1]
            let count = pcm.count / 2
            var floats = [Float](repeating: 0, count: count)
            pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let i16 = raw.bindMemory(to: Int16.self)
                for i in 0..<count {
                    floats[i] = Float(i16[i]) / 32768.0
                }
            }
            floats.withUnsafeBufferPointer { buffer.write($0) }

        case "doa":
            if let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                if let angle = dict["angle_rad"] as? Double {
                    lastDoaRad = angle
                }
                if let speech = dict["is_speech"] as? Bool {
                    lastDoaIsSpeech = speech
                }
            }
        default:
            break
        }
    }
}
