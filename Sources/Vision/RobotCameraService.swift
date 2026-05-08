import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif
import SidecarHost
import Telemetry

/// Pulls JPEG frames from the `robot-camera` Python sidecar (which runs the
/// reachy_mini SDK over WebRTC) and exposes them as decoded `CGImage`s
/// plus an optional `NSImage` for direct SwiftUI display.
public actor RobotCameraService {
    public struct Frame: Sendable {
        public let seq: Int
        public let width: Int
        public let height: Int
        public let sourceWidth: Int
        public let sourceHeight: Int
        public let jpeg: Data
    }

    public nonisolated let frames: AsyncStream<Frame>
    private let framesContinuation: AsyncStream<Frame>.Continuation

    private let sidecar: any Sidecar
    private let logBus: LogBus
    private var pumpTask: Task<Void, Never>?
    public private(set) var isStreaming: Bool = false
    public private(set) var lastSeq: Int = 0
    public private(set) var lastFrameAt: Date?
    /// First `.state(.ready)` is the initial start in `start()` — we
    /// already issued `start_streaming` synchronously. Subsequent
    /// `.ready` transitions are supervisor restarts (e.g. after the
    /// runner's 20s fatal exit) that need streaming re-armed.
    private var seenInitialReady: Bool = false

    public init(sidecar: any Sidecar, logBus: LogBus) {
        self.sidecar = sidecar
        self.logBus = logBus
        var c: AsyncStream<Frame>.Continuation!
        self.frames = AsyncStream<Frame>(
            bufferingPolicy: .bufferingNewest(2)
        ) { cont in c = cont }
        self.framesContinuation = c
    }

    public func start() async throws {
        try await sidecar.start()
        try await sendStartStreaming()

        // Single pump consuming both frame events and lifecycle
        // state changes — AsyncStream is effectively single-consumer,
        // so two iterators competing over `sidecar.events` would
        // race for each item and randomly drop frames or state
        // transitions.
        let events = sidecar.events
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.handleSidecarEvent(event)
                if Task.isCancelled { break }
            }
        }
        isStreaming = true
    }

    public func stop() async {
        pumpTask?.cancel(); pumpTask = nil
        isStreaming = false
        struct Empty: Encodable, Sendable {}
        struct R: Decodable, Sendable { let streaming: Bool }
        let _: R? = try? await sidecar.send(method: "stop_streaming", params: Empty())
    }

    /// Hits the sidecar's `start_streaming` RPC. Caller handles errors.
    private func sendStartStreaming() async throws {
        struct Empty: Encodable, Sendable {}
        struct R: Decodable, Sendable { let streaming: Bool }
        let _: R = try await sidecar.send(method: "start_streaming", params: Empty())
    }

    private func handleSidecarEvent(_ event: SidecarOutboundEvent) async {
        switch event {
        case .event(let name, let payload):
            if name == "frame" { await ingest(payload) }
        case .state(let s):
            // Re-arm streaming on supervisor-driven restarts (the
            // runner's stall watchdog → fatal exit → respawn). The
            // sidecar's init already runs acquire_media on its main
            // thread, so the new process is ready to stream once it
            // gets `start_streaming` back.
            if s == .ready {
                if !seenInitialReady {
                    seenInitialReady = true
                } else if isStreaming {
                    do {
                        try await sendStartStreaming()
                        await logBus.publish(.sidecarLog(
                            sidecar: "robot-camera", level: .info,
                            message: "re-armed streaming after restart",
                            fields: [:]
                        ))
                    } catch {
                        await logBus.publish(.error(
                            scope: "robot-camera",
                            message: "re-arm failed: \(error)",
                            recoverable: true
                        ))
                    }
                }
            }
        case .log:
            break
        }
    }

    private func ingest(_ payload: Data) async {
        guard
            let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let b64 = dict["jpeg_b64"] as? String,
            let jpeg = Data(base64Encoded: b64),
            let width = dict["width"] as? Int,
            let height = dict["height"] as? Int,
            let seq = dict["seq"] as? Int
        else { return }
        let srcW = (dict["source_width"] as? Int) ?? width
        let srcH = (dict["source_height"] as? Int) ?? height
        lastSeq = seq
        let frame = Frame(seq: seq, width: width, height: height,
                          sourceWidth: srcW, sourceHeight: srcH, jpeg: jpeg)
        lastFrameAt = Date()
        framesContinuation.yield(frame)
    }
}
