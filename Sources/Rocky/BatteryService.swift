import Foundation
import Telemetry

/// Polls the on-bot `rocky_media_relay` `/battery` endpoint and
/// publishes snapshots. Battery state changes slowly so a 30 s poll
/// is plenty; we back off to 60 s after consecutive failures so a
/// bot that doesn't expose the BMS to userspace doesn't burn cycles.
///
/// Independent of the robot daemon (port 8000) and the WS subscribers
/// — a daemon outage or a paused camera does not block battery
/// reads, and conversely a missing relay app doesn't break the
/// daemon's other functions. This actor publishes to an `AsyncStream`
/// that AppServices subscribes to and mirrors onto its `@Observable`
/// surface for SwiftUI to read.
public actor BatteryService {
    public struct Snapshot: Sendable, Equatable {
        public let present: Bool
        public let percent: Int?
        public let status: String?
        public let charging: Bool?
        public let pluggedIn: Bool?
        public let voltageV: Double?
        public let currentA: Double?
        public let temperatureC: Double?
        public let source: String?
        /// `true` when the most recent fetch reached the relay; false
        /// when the HTTP call failed. Decoupled from `present` so the
        /// UI can distinguish "bot says no BMS" from "relay
        /// unreachable".
        public let reachable: Bool
        public let fetchedAt: Date

        public static let unknown = Snapshot(
            present: false, percent: nil, status: nil,
            charging: nil, pluggedIn: nil,
            voltageV: nil, currentA: nil, temperatureC: nil,
            source: nil, reachable: false, fetchedAt: .distantPast
        )
    }

    public nonisolated let snapshots: AsyncStream<Snapshot>
    private let continuation: AsyncStream<Snapshot>.Continuation

    private let host: String
    private let port: Int
    private let logBus: LogBus
    private let okIntervalNs: UInt64 = 30 * 1_000_000_000
    private let failIntervalNs: UInt64 = 60 * 1_000_000_000
    private var task: Task<Void, Never>?

    public init(host: String, port: Int = 8042, logBus: LogBus) {
        self.host = host
        self.port = port
        self.logBus = logBus
        var c: AsyncStream<Snapshot>.Continuation!
        self.snapshots = AsyncStream<Snapshot>(
            bufferingPolicy: .bufferingNewest(1)
        ) { cont in c = cont }
        self.continuation = c
    }

    public func start() {
        if task != nil { return }
        task = Task { [weak self] in await self?.loop() }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            let snap = await fetchOnce()
            continuation.yield(snap)
            let interval: UInt64
            if snap.reachable {
                consecutiveFailures = 0
                interval = okIntervalNs
            } else {
                consecutiveFailures += 1
                interval = consecutiveFailures > 1
                    ? failIntervalNs : okIntervalNs
            }
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    private func fetchOnce() async -> Snapshot {
        guard let url = URL(string: "http://\(host):\(port)/battery") else {
            return .unknown
        }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "GET"
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200
            else { return .unknown }
            let parsed = decode(data) ?? .unknown
            return parsed
        } catch {
            return Snapshot(
                present: false, percent: nil, status: nil,
                charging: nil, pluggedIn: nil,
                voltageV: nil, currentA: nil, temperatureC: nil,
                source: nil, reachable: false, fetchedAt: Date()
            )
        }
    }

    private func decode(_ data: Data) -> Snapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Snapshot(
            present: (obj["present"] as? Bool) ?? false,
            percent: obj["percent"] as? Int,
            status: obj["status"] as? String,
            charging: obj["charging"] as? Bool,
            pluggedIn: obj["plugged_in"] as? Bool,
            voltageV: obj["voltage_v"] as? Double,
            currentA: obj["current_a"] as? Double,
            temperatureC: obj["temperature_c"] as? Double,
            source: obj["source"] as? String,
            reachable: true,
            fetchedAt: Date()
        )
    }
}
