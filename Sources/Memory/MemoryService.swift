import Foundation
import SidecarHost
import Telemetry

/// Typed adapter over the `mempalace` Python sidecar. Provides verbatim
/// conversation storage + semantic recall so Rocky can reach back into
/// prior sessions instead of starting cold every time.
///
/// Usage shape from `CognitionEngine`:
///   - **pre-turn**: `recall(query: userText, k: 5)` to fetch top-K
///     drawers as plain strings; the engine prepends them as a system
///     message for that single turn.
///   - **post-turn**: `record(role: .user, text:)` and
///     `record(role: .assistant, text:)` after the assistant final lands.
///     Fire-and-forget — recall is the latency-sensitive path; writes
///     just need to land before the next session starts.
public actor MemoryService {
    public enum Role: String, Sendable {
        case user
        case assistant
        case tool
        case system
    }

    public struct Hit: Sendable, Equatable {
        public let text: String
        public let score: Double?
        public let distance: Double?
        public let id: String?

        public init(text: String, score: Double?, distance: Double?, id: String?) {
            self.text = text
            self.score = score
            self.distance = distance
            self.id = id
        }
    }

    public nonisolated let sidecar: any Sidecar
    private let logBus: LogBus

    public init(sidecar: any Sidecar, logBus: LogBus) {
        self.sidecar = sidecar
        self.logBus = logBus
    }

    public func start() async throws {
        try await sidecar.start()
    }

    public func stop() async {
        await sidecar.stop()
    }

    // MARK: - Control methods (forwarded to the sidecar)

    /// Idempotent: ensures the palace directory has the bootstrap
    /// `mempalace.yaml` and chroma stores. Safe to call many times;
    /// real init only happens on first run.
    public func initPalace() async throws -> InitResult {
        struct P: Encodable, Sendable {}
        return try await sidecar.send(method: "init_palace", params: P())
    }

    /// Append a verbatim drawer for a single utterance.
    public func record(role: Role, text: String) async throws -> AddResult {
        struct P: Encodable, Sendable { let role: String; let text: String }
        return try await sidecar.send(
            method: "add",
            params: P(role: role.rawValue, text: text)
        )
    }

    /// Chronological page through every drawer in the configured
    /// wing/room. Distinct from `recall` (which is semantic) — this
    /// returns the most-recent N entries in order so the Memory tab
    /// can show what's actually stored. The Hit shape is reused for
    /// rendering symmetry; `score` / `distance` are nil for listed
    /// drawers.
    public func listDrawers(limit: Int = 50, offset: Int = 0)
        async throws -> [Hit]
    {
        struct P: Encodable, Sendable { let limit: Int; let offset: Int }
        let resp: ListResponse = try await sidecar.send(
            method: "list",
            params: P(limit: limit, offset: offset)
        )
        return resp.drawers.map {
            Hit(
                text: $0.text,
                score: nil,
                distance: nil,
                id: $0.id.isEmpty ? nil : $0.id
            )
        }
    }

    /// Delete a single drawer by id. Used by the per-row delete
    /// button in the Memory tab so the user can prune individual
    /// entries instead of nuking the whole palace via
    /// `forgetAll()`.
    @discardableResult
    public func deleteDrawer(id: String) async throws -> Bool {
        struct P: Encodable, Sendable { let id: String }
        let resp: DeleteResponse = try await sidecar.send(
            method: "delete",
            params: P(id: id)
        )
        return resp.deleted
    }

    /// Top-K semantically-similar drawers for a query. Pure read.
    public func recall(query: String, k: Int = 5) async throws -> [Hit] {
        struct P: Encodable, Sendable { let query: String; let k: Int }
        let resp: RecallResponse = try await sidecar.send(
            method: "recall",
            params: P(query: query, k: k)
        )
        return resp.hits
    }

    /// Total drawer count for the configured wing/room. Cheap probe;
    /// surfaced in Settings so the user can see how much history Rocky
    /// has accumulated.
    public func count() async throws -> Int {
        struct P: Encodable, Sendable {}
        let resp: CountResponse = try await sidecar.send(
            method: "count", params: P()
        )
        return resp.count
    }

    /// Delete every drawer in the configured wing/room. Destructive;
    /// the Settings UI confirms before calling.
    @discardableResult
    public func forgetAll() async throws -> Int {
        struct P: Encodable, Sendable {}
        let resp: ForgetAllResponse = try await sidecar.send(
            method: "forget_all", params: P()
        )
        return resp.deleted
    }

    /// Fire-and-forget variants for callsites that shouldn't block on
    /// memory I/O (post-turn writes from `CognitionEngine`). Failures
    /// surface in the LogBus rather than propagating up.
    public nonisolated func recordDetached(role: Role, text: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.record(role: role, text: text)
            } catch {
                await self.logBus.publish(.error(
                    scope: "memory.record",
                    message: "\(role.rawValue): \(error)",
                    recoverable: true
                ))
            }
        }
    }

    // MARK: - Wire envelopes

    public struct InitResult: Decodable, Sendable {
        public let ok: Bool
        public let path: String?
        public let wing: String?
        public let room: String?
    }

    public struct AddResult: Decodable, Sendable {
        public let stored: Bool
        public let id: String?
        public let role: String?
        public let ts: String?
        public let error: String?
    }

    private struct RecallResponse: Decodable, Sendable {
        let hits: [Hit]
        let count: Int?
        let error: String?
    }

    private struct CountResponse: Decodable, Sendable {
        let count: Int
        let error: String?
    }

    private struct ForgetAllResponse: Decodable, Sendable {
        let deleted: Int
        let wing: String?
        let room: String?
        let error: String?
    }

    private struct ListResponse: Decodable, Sendable {
        struct DrawerRow: Decodable, Sendable {
            let id: String
            let text: String
            let role: String
            let ts: String
        }
        let drawers: [DrawerRow]
        let total: Int
        let error: String?
    }

    private struct DeleteResponse: Decodable, Sendable {
        let deleted: Bool
        let id: String?
        let error: String?
    }
}

extension MemoryService.Hit: Decodable {
    enum CodingKeys: String, CodingKey {
        case text, score, distance, id
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decode(String.self, forKey: .text)
        self.score = try c.decodeIfPresent(Double.self, forKey: .score)
        self.distance = try c.decodeIfPresent(Double.self, forKey: .distance)
        self.id = try c.decodeIfPresent(String.self, forKey: .id)
    }
}
