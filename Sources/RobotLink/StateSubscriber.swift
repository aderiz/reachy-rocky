import Foundation
import RockyKit
import Telemetry

/// Subscribes to the daemon's `/api/state/ws/full` WebSocket and emits
/// `RobotState` updates as an `AsyncStream`. Reconnects with backoff on
/// transport errors so the dashboard stays honest about connectivity.
public actor StateSubscriber {
    public enum Status: Sendable, Equatable {
        case stopped, connecting, streaming, reconnecting(reason: String)
    }

    public let endpoint: RobotEndpoint
    public nonisolated let states: AsyncStream<RobotState>
    private let statesContinuation: AsyncStream<RobotState>.Continuation
    private let logBus: LogBus
    private let session: URLSession

    private(set) public var status: Status = .stopped
    private var pumpTask: Task<Void, Never>?
    private var ws: URLSessionWebSocketTask?

    public init(
        endpoint: RobotEndpoint,
        session: URLSession = .shared,
        logBus: LogBus
    ) {
        self.endpoint = endpoint
        self.session = session
        self.logBus = logBus
        var c: AsyncStream<RobotState>.Continuation!
        self.states = AsyncStream<RobotState>(
            bufferingPolicy: .bufferingNewest(64)
        ) { cont in c = cont }
        self.statesContinuation = c
    }

    public func start() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            await self?.pumpLoop()
        }
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        status = .stopped
    }

    private func pumpLoop() async {
        // Same `with_*=true` flags as the REST `fullState()` so the
        // streamed `RobotState` includes head_joints, body_yaw,
        // antennas_position and passive_joints.
        let url = endpoint.wsURL(
            "/api/state/ws/full?\(RobotLinkClient.fullStateQuery)"
        )
        var attempt = 0
        while !Task.isCancelled {
            status = attempt == 0 ? .connecting : .reconnecting(reason: "retry \(attempt)")
            let task = session.webSocketTask(with: url)
            self.ws = task
            task.resume()
            attempt += 1
            do {
                status = .streaming
                while !Task.isCancelled {
                    let msg = try await task.receive()
                    switch msg {
                    case .string(let s):
                        if let data = s.data(using: .utf8) {
                            await ingest(data)
                        }
                    case .data(let data):
                        await ingest(data)
                    @unknown default:
                        continue
                    }
                }
            } catch {
                status = .reconnecting(reason: "\(error)")
                await logBus.publish(.error(
                    scope: "state-ws",
                    message: "\(error)",
                    recoverable: true
                ))
            }
            ws?.cancel()
            ws = nil
            // Backoff: 250ms, 500ms, 1s, 2s, 4s, capped 5s.
            let backoffMs = min(5000, 250 * Int(pow(2.0, Double(min(attempt, 6)))))
            try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
        }
        status = .stopped
    }

    private func ingest(_ data: Data) async {
        do {
            let state = try JSONDecoder().decode(RobotState.self, from: data)
            statesContinuation.yield(state)
            await logBus.publish(.motorState(state))
        } catch {
            await logBus.publish(.error(
                scope: "state-ws",
                message: "decode: \(error)",
                recoverable: true
            ))
        }
    }
}
