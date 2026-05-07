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
        struct Empty: Encodable, Sendable {}
        struct R: Decodable, Sendable { let streaming: Bool }
        let _: R = try await sidecar.send(method: "start_streaming", params: Empty())

        let events = sidecar.events
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            for await event in events {
                if case .event(let name, let payload) = event, name == "frame" {
                    await self?.ingest(payload)
                }
                if Task.isCancelled { break }
            }
        }
        isStreaming = true
    }

    public func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        isStreaming = false
        struct Empty: Encodable, Sendable {}
        struct R: Decodable, Sendable { let streaming: Bool }
        let _: R? = try? await sidecar.send(method: "stop_streaming", params: Empty())
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
        framesContinuation.yield(frame)
    }
}
