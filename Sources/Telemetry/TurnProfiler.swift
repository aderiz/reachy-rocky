import Foundation

/// End-to-end turn profiler.
///
/// Subscribes to LogBus, aggregates per-turn timings, and pushes a
/// completed `TurnProfile` to a `ProfileStore` consumer plus emits
/// `.turnProfile` + `[profile] PROFILE` log events.
///
/// **Turn boundaries (current rules, after the 13:03–13:06 data review):**
///   - **Open** on `.sttFinal` — that's the first event we can confidently
///     attribute to a real dispatch. Opening on `.vadSegment` produced
///     a flood of stale rows from echo, deduped utterances, and
///     wake-filter rejections.
///   - **Close** on the next `.sttFinal` (the user spoke again — previous
///     turn is over) OR after a 30 s idle timer (the response landed and
///     no follow-up came).
///   - **Multiple speak invocations within one turn** (e.g. preamble
///     `express` + answer `say`) collapse into the same record: the
///     first `.audioPlaybackStarted` is the user-perceived response
///     start (`audioFirstMs`); the last one is when the actual answer
///     started (`audioLastMs`); `audioCount` is the total.
///
/// User-perceived metrics:
///   - `audioFirstMs` — STT-final → first audio on robot (the moment
///     Rocky started making any sound; might be a preamble).
///   - `audioLastMs` — STT-final → last audio on robot (the moment
///     Rocky's actual *answer* started, if there was a preamble).
///   - `brainRounds` — number of `.brainResponse` events seen. >1 means
///     the brain did multiple roundtrips (e.g. preamble say → tool →
///     final say), which is a major latency contributor.
public actor TurnProfiler {
    private let logBus: LogBus
    private let store: ProfileStore
    private var enabled: Bool = false
    private var current: PartialTurn?
    private var subscription: Task<Void, Never>?
    private var idleFlushTask: Task<Void, Never>?

    /// Idle time after the last activity in a turn before we auto-flush
    /// it. Long enough that a paused TTS playback doesn't trigger an
    /// early flush, short enough that a hung sidecar still produces a
    /// profile row eventually.
    private let idleFlushS: TimeInterval = 30

    public init(logBus: LogBus, store: ProfileStore) {
        self.logBus = logBus
        self.store = store
    }

    public func setEnabled(_ value: Bool) async {
        let wasEnabled = self.enabled
        self.enabled = value
        if value, subscription == nil {
            let bus = logBus
            self.subscription = Task { [weak self] in
                for await stamped in await bus.subscribe() {
                    guard let self else { return }
                    await self.handle(stamped)
                }
            }
        }
        if !value {
            current = nil
            idleFlushTask?.cancel()
            idleFlushTask = nil
        }
        if wasEnabled != value {
            await logBus.publish(.sidecarLog(
                sidecar: "profile",
                level: .info,
                message: value
                    ? "profiling ON — open Inspector → Profile to see per-turn waterfalls"
                    : "profiling off",
                fields: [:]
            ))
        }
    }

    // MARK: - Partial-turn aggregation

    fileprivate struct PartialTurn {
        var turnStartedAt: Date
        var sttFinalAt: Date?
        var sttDurationMs: Double?
        var addressAcceptAt: Date?
        var brainRounds: [BrainRound] = []
        var tools: [TurnProfile.ToolCall] = []
        var saySynthMs: Double?
        var sayUploadMs: Double?
        var audioStartedAtFirst: Date?
        var audioStartedAtLast: Date?
        var audioFirstSinceSpeakMs: Double?
        var audioLastSinceSpeakMs: Double?
        var audioCount: Int = 0
        var audioDurationS: Double?
        var lastEventAt: Date
    }

    fileprivate struct BrainRound {
        let at: Date
        let firstChunkMs: Double?
        let totalMs: Double
    }

    private func handle(_ stamped: TimestampedEvent) async {
        guard enabled else { return }
        let ts = stamped.timestamp
        switch stamped.event {
        case .sttFinal(_, let totalMs):
            // New turn. Flush any prior turn that didn't reach a
            // natural close — this is the cleanest boundary signal
            // we get (the user spoke again, so the previous reply
            // is "done" by definition).
            if current != nil { await flushCurrent(reason: .nextTurn) }
            current = PartialTurn(
                turnStartedAt: ts,
                sttFinalAt: ts,
                sttDurationMs: totalMs,
                lastEventAt: ts
            )
            scheduleIdleFlush()

        case .addressFilterAccept:
            updateCurrent { $0.addressAcceptAt = ts }
            touch(at: ts)

        case .addressFilterDrop:
            // Rejected at dispatch — surface immediately so the user
            // can see why their utterance didn't get a reply.
            updateCurrent { $0.lastEventAt = ts }
            await flushCurrent(reason: .addressDrop)

        case .brainResponse(let firstChunkMs, let totalMs):
            updateCurrent {
                $0.brainRounds.append(
                    .init(at: ts, firstChunkMs: firstChunkMs, totalMs: totalMs)
                )
            }
            touch(at: ts)

        case .toolInvocation(let name, _, let result, let latencyMs, _):
            updateCurrent { c in
                c.tools.append(.init(name: name, latencyMs: latencyMs, at: ts))
                // `say` carries `synth_ms` / `upload_ms` / `duration_s`
                // in its result envelope. Parse once into locals so we
                // don't trip the exclusivity check on read-modify-write
                // of `c.audioDurationS` etc. — that was the SIGABRT in
                // the previous build.
                guard name == "say",
                      let data = result.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(
                        with: data
                      ) as? [String: Any]
                else { return }
                if let dur = dict["duration_s"] as? Double {
                    let existing = c.audioDurationS ?? 0
                    c.audioDurationS = existing + dur
                }
                if c.saySynthMs == nil,
                   let synth = dict["synth_ms"] as? Double
                {
                    c.saySynthMs = synth
                }
                if let upload = dict["upload_ms"] as? Double {
                    let existing = c.sayUploadMs ?? 0
                    c.sayUploadMs = existing + upload
                }
            }
            touch(at: ts)

        case .audioPlaybackStarted(_, let sinceSpeak):
            updateCurrent { c in
                c.audioCount += 1
                if c.audioStartedAtFirst == nil {
                    c.audioStartedAtFirst = ts
                    c.audioFirstSinceSpeakMs = sinceSpeak
                }
                c.audioStartedAtLast = ts
                c.audioLastSinceSpeakMs = sinceSpeak
            }
            touch(at: ts)
            // Don't flush here — there may be more speak invocations
            // coming (preamble + answer). Idle timer will close us.

        default:
            break
        }
    }

    /// Load `current` into a local, mutate, store back. The
    /// `current?.X = Y` / `current?.X = (current?.X ?? 0) + Y`
    /// patterns trip Swift's exclusivity check at runtime because the
    /// read and write of the chained-optional storage overlap on the
    /// `current` stored property. The previous build SIGABRT'd in
    /// `swift_beginAccess` from this exact pattern. Routing every
    /// mutation through this helper keeps each access atomic.
    private func updateCurrent(_ mutate: (inout PartialTurn) -> Void) {
        guard var c = current else { return }
        mutate(&c)
        current = c
    }

    /// Bump `lastEventAt` and reset the idle-flush timer. Each
    /// substantive event extends the turn's lifespan.
    private func touch(at: Date) {
        updateCurrent { $0.lastEventAt = at }
        scheduleIdleFlush()
    }

    /// (Re)schedule the idle-flush timer. Cancelled and re-armed on
    /// every event so the timeout is "30 s of complete silence", not
    /// "30 s since the turn started".
    private func scheduleIdleFlush() {
        idleFlushTask?.cancel()
        let delay = idleFlushS
        idleFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flushIfIdle()
        }
    }

    private func flushIfIdle() async {
        guard enabled, current != nil else { return }
        await flushCurrent(reason: .idle)
    }

    private enum FlushReason {
        case nextTurn      // next sttFinal landed (previous turn is over)
        case addressDrop   // AddressFilter rejected the dispatch
        case idle          // 30 s of no activity
    }

    private func flushCurrent(reason: FlushReason) async {
        guard let p = current else { return }
        current = nil
        idleFlushTask?.cancel()
        idleFlushTask = nil
        let outcome: TurnProfile.Outcome
        switch reason {
        case .nextTurn:    outcome = p.audioStartedAtFirst != nil ? .complete : .notDispatched
        case .addressDrop: outcome = .addressDrop
        case .idle:        outcome = p.audioStartedAtFirst != nil ? .complete : .notDispatched
        }
        let profile = TurnProfile.build(from: p, outcome: outcome)
        await store.append(profile)
        await logBus.publish(.turnProfile(
            summary: profile.summaryLine,
            fields: profile.fields
        ))
        await logBus.publish(.sidecarLog(
            sidecar: "profile",
            level: .info,
            message: "PROFILE  " + profile.summaryLine,
            fields: profile.fields
        ))
    }
}

// MARK: - TurnProfile (immutable finished record)

public struct TurnProfile: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date

    /// STT-final → first audio on robot. Closest signal to
    /// "Rocky started responding."
    public let audioFirstMs: Double?
    /// STT-final → LAST audio on robot. When there's a preamble
    /// (e.g. `express` + `say`), this is the moment the answer
    /// started rather than the chatter.
    public let audioLastMs: Double?
    /// Number of distinct speak invocations within the turn. >1 means
    /// the brain emitted a preamble + answer (doubling TTS cost).
    public let audioCount: Int

    public let sttMs: Double?
    public let sttToAddrMs: Double?
    public let brainRounds: Int
    public let brainFirstChunkMs: Double?
    public let brainTotalMs: Double?
    public let sayFirstSynthMs: Double?
    public let sayUploadMs: Double?
    public let audioDurationS: Double?
    public let tools: [ToolCall]
    public let outcome: Outcome

    public struct ToolCall: Sendable, Equatable {
        public let name: String
        public let latencyMs: Double
        public let at: Date
        public init(name: String, latencyMs: Double, at: Date) {
            self.name = name; self.latencyMs = latencyMs; self.at = at
        }
    }

    public enum Outcome: Sendable, Equatable {
        case complete       // reached at least one audioPlaybackStarted
        case addressDrop    // AddressFilter rejected dispatch
        case notDispatched  // STT fired but nothing reached audio (echo, hang, drop)
    }

    fileprivate static func build(
        from p: TurnProfiler.PartialTurn,
        outcome: Outcome
    ) -> TurnProfile {
        let audioFirstMs = p.audioStartedAtFirst.map {
            $0.timeIntervalSince(p.turnStartedAt) * 1000
        }
        let audioLastMs = p.audioStartedAtLast.map {
            $0.timeIntervalSince(p.turnStartedAt) * 1000
        }
        let sttToAddrMs: Double? = {
            guard let stt = p.sttFinalAt, let addr = p.addressAcceptAt
            else { return nil }
            return addr.timeIntervalSince(stt) * 1000
        }()
        // Sum brain rounds for total brain time across the turn.
        // For the user-perceived "brain thinking" cost across multi-
        // round turns (preamble → tool → answer), this is what matters.
        let brainTotalMs = p.brainRounds.isEmpty
            ? nil
            : p.brainRounds.map(\.totalMs).reduce(0, +)
        let brainFirstChunkMs = p.brainRounds.first?.firstChunkMs
        return TurnProfile(
            id: UUID(),
            timestamp: p.turnStartedAt,
            audioFirstMs: audioFirstMs,
            audioLastMs: audioLastMs,
            audioCount: p.audioCount,
            sttMs: p.sttDurationMs,
            sttToAddrMs: sttToAddrMs,
            brainRounds: p.brainRounds.count,
            brainFirstChunkMs: brainFirstChunkMs,
            brainTotalMs: brainTotalMs,
            sayFirstSynthMs: p.saySynthMs,
            sayUploadMs: p.sayUploadMs,
            audioDurationS: p.audioDurationS,
            tools: p.tools,
            outcome: outcome
        )
    }

    public init(
        id: UUID, timestamp: Date,
        audioFirstMs: Double?, audioLastMs: Double?, audioCount: Int,
        sttMs: Double?, sttToAddrMs: Double?,
        brainRounds: Int, brainFirstChunkMs: Double?, brainTotalMs: Double?,
        sayFirstSynthMs: Double?, sayUploadMs: Double?,
        audioDurationS: Double?, tools: [ToolCall], outcome: Outcome
    ) {
        self.id = id; self.timestamp = timestamp
        self.audioFirstMs = audioFirstMs; self.audioLastMs = audioLastMs
        self.audioCount = audioCount
        self.sttMs = sttMs; self.sttToAddrMs = sttToAddrMs
        self.brainRounds = brainRounds
        self.brainFirstChunkMs = brainFirstChunkMs; self.brainTotalMs = brainTotalMs
        self.sayFirstSynthMs = sayFirstSynthMs; self.sayUploadMs = sayUploadMs
        self.audioDurationS = audioDurationS
        self.tools = tools; self.outcome = outcome
    }

    // MARK: - Rendering

    public var summaryLine: String {
        var parts: [String] = []
        if let v = audioFirstMs { parts.append(String(format: "1st-audio %.0f ms", v)) }
        if let v = audioLastMs, audioCount > 1 {
            parts.append(String(format: "answer %.0f ms", v))
        }
        if let v = sttMs { parts.append(String(format: "stt %.0f", v)) }
        if let v = brainTotalMs {
            if brainRounds > 1 {
                parts.append(String(format: "brain %.0f ms (×%d rounds)", v, brainRounds))
            } else {
                parts.append(String(format: "brain %.0f", v))
            }
        }
        if !tools.isEmpty {
            let tp = tools
                .map { String(format: "%@ %.0f", $0.name, $0.latencyMs) }
                .joined(separator: ", ")
            parts.append("[\(tp)]")
        }
        if audioCount > 1 {
            parts.append("\(audioCount)× audio")
        }
        return parts.joined(separator: " · ")
    }

    public var fields: [String: String] {
        var out: [String: String] = [
            "outcome": String(describing: outcome),
            "audio_count": String(audioCount),
            "brain_rounds": String(brainRounds),
        ]
        func f(_ v: Double?, _ key: String) {
            if let v { out[key] = String(format: "%.0f", v) }
        }
        f(audioFirstMs, "audio_first_ms")
        f(audioLastMs, "audio_last_ms")
        f(sttMs, "stt_ms")
        f(sttToAddrMs, "stt_to_addr_ms")
        f(brainFirstChunkMs, "brain_first_chunk_ms")
        f(brainTotalMs, "brain_total_ms")
        f(sayFirstSynthMs, "say_first_synth_ms")
        f(sayUploadMs, "say_upload_ms")
        if let dur = audioDurationS {
            out["audio_s"] = String(format: "%.1f", dur)
        }
        if !tools.isEmpty {
            out["tools"] = tools
                .map { String(format: "%@:%.0f", $0.name, $0.latencyMs) }
                .joined(separator: ",")
        }
        return out
    }
}

// MARK: - ProfileStore

public actor ProfileStore {
    public let capacity: Int
    private(set) public var profiles: [TurnProfile] = []
    private var subscribers: [UUID: AsyncStream<[TurnProfile]>.Continuation] = [:]

    public init(capacity: Int = 50) {
        self.capacity = capacity
    }

    public func append(_ profile: TurnProfile) {
        profiles.append(profile)
        if profiles.count > capacity {
            profiles.removeFirst(profiles.count - capacity)
        }
        let snap = profiles
        for cont in subscribers.values { cont.yield(snap) }
    }

    public func clear() {
        profiles.removeAll()
        for cont in subscribers.values { cont.yield([]) }
    }

    public func snapshot() -> [TurnProfile] { profiles }

    public func subscribe() -> AsyncStream<[TurnProfile]> {
        let id = UUID()
        return AsyncStream<[TurnProfile]> { continuation in
            self.attach(id: id, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.detach(id: id) }
            }
        }
    }

    private func attach(id: UUID, continuation: AsyncStream<[TurnProfile]>.Continuation) {
        subscribers[id] = continuation
        continuation.yield(profiles)
    }

    private func detach(id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    public static func aggregates(of profiles: [TurnProfile]) -> Aggregates {
        Aggregates(profiles: profiles)
    }

    public struct Aggregates: Sendable {
        public let count: Int
        public let p50AudioFirstMs: Double?
        public let p95AudioFirstMs: Double?
        public let p50AudioLastMs: Double?
        public let p95AudioLastMs: Double?
        public let p50BrainTotalMs: Double?
        public let p95BrainTotalMs: Double?

        init(profiles: [TurnProfile]) {
            let complete = profiles.filter { $0.outcome == .complete }
            count = complete.count
            let first = complete.compactMap(\.audioFirstMs).sorted()
            let last = complete.compactMap(\.audioLastMs).sorted()
            let brain = complete.compactMap(\.brainTotalMs).sorted()
            p50AudioFirstMs = Self.pct(first, 0.50)
            p95AudioFirstMs = Self.pct(first, 0.95)
            p50AudioLastMs = Self.pct(last, 0.50)
            p95AudioLastMs = Self.pct(last, 0.95)
            p50BrainTotalMs = Self.pct(brain, 0.50)
            p95BrainTotalMs = Self.pct(brain, 0.95)
        }

        private static func pct(_ sorted: [Double], _ p: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            let idx = max(0, min(sorted.count - 1,
                                  Int((Double(sorted.count - 1) * p).rounded())))
            return sorted[idx]
        }
    }
}
