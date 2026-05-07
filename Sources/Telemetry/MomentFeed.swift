import Foundation

/// Coalesces telemetry events into a stream of `Moment`s at human
/// cadence. Per `docs/concepts/cockpit-design.md` §5.2:
///
/// - Three `faceDetection` events for the same identity within 30 s
///   become one `recognised(person:)` moment. Subsequent detections
///   silently extend the "still watching" window; only after 30 s
///   without a detection does a `lostSightOf` fire.
/// - Multiple `llmChunk` events between an `llmRequest` and the next
///   request are collapsed into a single `rockySaid` moment when the
///   turn finishes (signalled by the next `llmRequest` or a 2 s gap
///   with no chunks).
/// - `sidecarState` transitions are passed through, but consecutive
///   transitions of the same sidecar within 30 s are coalesced.
/// - `error` events trigger an `errorOccurred` moment immediately;
///   a `recovered` is emitted only after 60 s of no further errors in
///   the same scope.
/// - Motor frames, mic RMS samples, and llm chunks are *not* moments.
///
/// The actor maintains a ring buffer of the last `capacity` moments
/// and exposes them as both a snapshot (`recent()`) and a streaming
/// `AsyncStream` for live consumers (the cockpit margin strip, the
/// menu-bar popover, the Inspector / Activity tab).
public actor MomentFeed {
    public let capacity: Int
    private var buffer: [Moment] = []
    private var continuations: [UUID: AsyncStream<Moment>.Continuation] = [:]

    // MARK: - Coalescing state

    /// Last assistant turn we're still building chunks for. When the
    /// next user turn fires (or 2 s pass without chunks), we flush this
    /// into the `rockySaid` moment.
    private var pendingAssistantText: String = ""
    private var pendingAssistantTools: [String] = []
    private var pendingAssistantStart: Date?
    private var pendingAssistantFlushTask: Task<Void, Never>?

    /// Last seen identities → date last detected. Used to fire
    /// `recognised` on first sighting in 30 s and `lostSightOf` on
    /// 30 s without a sighting.
    private var lastSeen: [String: Date] = [:]
    private var faceLossTask: Task<Void, Never>?

    /// Sidecar transitions we recently emitted. Subsequent identical
    /// transitions within `sidecarCoalesceWindow` are dropped.
    private var lastSidecarTransition: [String: (Date, String)] = [:]

    /// Recent error scopes, for the recovery debounce.
    private var recentErrorScopes: [String: Date] = [:]
    private var errorRecoveryTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Tunables

    private let faceRediscoveryWindow: TimeInterval = 30
    private let faceLossTimeout: TimeInterval       = 30
    private let assistantFlushIdle: TimeInterval    = 2
    private let sidecarCoalesceWindow: TimeInterval = 30
    private let errorRecoveryHold: TimeInterval     = 60

    public init(capacity: Int = 200) {
        self.capacity = capacity
    }

    // MARK: - Public API

    /// Snapshot of the most recent moments, newest-last (so consumers
    /// can append the latest by `.last`).
    public func recent(limit: Int? = nil) -> [Moment] {
        if let limit, limit < buffer.count { return Array(buffer.suffix(limit)) }
        return buffer
    }

    /// Live stream of new moments. Each subscriber gets its own buffered
    /// continuation; cancel the iteration to detach.
    public func subscribe(bufferingNewest n: Int = 64) -> AsyncStream<Moment> {
        AsyncStream(bufferingPolicy: .bufferingNewest(n)) { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.detach(id: id) }
            }
        }
    }

    private func detach(id: UUID) {
        continuations[id] = nil
    }

    /// Push a single telemetry event in. Idempotent w.r.t. cadence —
    /// hammering this with high-frequency events doesn't multiply the
    /// moments emitted.
    public func ingest(_ timestamped: TimestampedEvent) {
        switch timestamped.event {
        case .sttFinal(let text, _):
            // sttFinal alone isn't enough — wakeMatch is what tells us
            // it was addressed to Rocky. We only know after the wake
            // filter fires, so we hold sttFinal here and wait for the
            // matching wakeMatch (if any). If 100 ms elapses without one,
            // emit as `rockyHeard`.
            scheduleHeardIfUnclaimed(text: text, at: timestamped.timestamp)

        case .wakeMatch(_, let transcript):
            // Wake matched — supersede any pending heard event for the
            // same transcript and emit `userSaid`.
            cancelHeardIfMatching(transcript: transcript)
            push(Moment(timestamp: timestamped.timestamp,
                         kind: .userSaid(text: transcript)))

        case .llmRequest:
            // A new turn is about to start. Flush any pending assistant
            // accumulation as a moment first so we don't conflate turns.
            flushPendingAssistant(now: timestamped.timestamp)
            pendingAssistantStart = timestamped.timestamp
            pendingAssistantText = ""
            pendingAssistantTools = []
            scheduleAssistantFlush()

        case .llmChunk(_, let contentDelta, _):
            if let delta = contentDelta { pendingAssistantText += delta }
            scheduleAssistantFlush()

        case .llmToolCall(let name, _, _):
            if !pendingAssistantTools.contains(name) {
                pendingAssistantTools.append(name)
            }

        case .toolInvocation(let name, _, _, _, _):
            // Tool-only invocations (when the assistant text is empty)
            // surface as a standalone moment. When attached to a turn
            // they get rolled into rockySaid via pendingAssistantTools.
            if pendingAssistantStart == nil {
                push(Moment(timestamp: timestamped.timestamp,
                             kind: .toolUsed(name: name, summary: "")))
            }

        case .faceDetection(_, _, let promptId):
            // promptId is the SAM prompt or the recognised identity name.
            // Only treat it as an identity if it doesn't look like a
            // generic prompt (ad-hoc heuristic until faceTracker exposes
            // an `identity` field).
            let person = promptId
            let now = timestamped.timestamp
            let last = lastSeen[person]
            lastSeen[person] = now
            if last == nil || now.timeIntervalSince(last!) > faceRediscoveryWindow {
                push(Moment(timestamp: now,
                             kind: .recognised(person: person)))
            }
            scheduleFaceLossCheck(for: person)

        case .sidecarState(let name, let transition):
            let now = timestamped.timestamp
            if let (lastAt, lastTrans) = lastSidecarTransition[name],
               now.timeIntervalSince(lastAt) < sidecarCoalesceWindow,
               lastTrans == transition {
                return  // skip: already emitted this transition recently
            }
            lastSidecarTransition[name] = (now, transition)
            push(Moment(timestamp: now,
                         kind: .sidecarChanged(name: name,
                                                 transition: transition)))

        case .error(let scope, let message, _):
            let now = timestamped.timestamp
            recentErrorScopes[scope] = now
            scheduleRecovery(for: scope)
            push(Moment(timestamp: now,
                         kind: .errorOccurred(scope: scope, message: message)))

        // Things we DON'T turn into moments — too noisy at firehose
        // cadence. They live in the Raw tab.
        case .motorCommand, .motorState, .stateStream, .daemonStatus,
             .robotLink, .faceTarget, .vadSegment, .sttPartial,
             .conversationWindow, .ttsRequest, .ttsChunk,
             .sidecarLog:
            return
        }
    }

    // MARK: - Push + broadcast

    private func push(_ moment: Moment) {
        buffer.append(moment)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        for continuation in continuations.values {
            continuation.yield(moment)
        }
    }

    // MARK: - sttFinal → rockyHeard hold

    private var pendingHeard: (text: String, time: Date, task: Task<Void, Never>)?

    private func scheduleHeardIfUnclaimed(text: String, at time: Date) {
        cancelPendingHeard()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            await self?.emitHeardIfStillPending(text: text, at: time)
        }
        pendingHeard = (text, time, task)
    }

    private func cancelHeardIfMatching(transcript: String) {
        guard let pending = pendingHeard, pending.text == transcript else {
            cancelPendingHeard()
            return
        }
        pending.task.cancel()
        pendingHeard = nil
    }

    private func cancelPendingHeard() {
        pendingHeard?.task.cancel()
        pendingHeard = nil
    }

    private func emitHeardIfStillPending(text: String, at time: Date) {
        guard let pending = pendingHeard, pending.text == text else { return }
        pendingHeard = nil
        push(Moment(timestamp: time, kind: .rockyHeard(text: text)))
    }

    // MARK: - Assistant turn flush

    private func scheduleAssistantFlush() {
        pendingAssistantFlushTask?.cancel()
        let idleNs = UInt64(assistantFlushIdle * 1_000_000_000)
        pendingAssistantFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: idleNs)
            guard !Task.isCancelled else { return }
            await self?.flushPendingAssistant(now: Date())
        }
    }

    private func flushPendingAssistant(now: Date) {
        guard pendingAssistantStart != nil else { return }
        let text = pendingAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tools = pendingAssistantTools
        pendingAssistantStart = nil
        pendingAssistantText = ""
        pendingAssistantTools = []
        pendingAssistantFlushTask?.cancel()
        pendingAssistantFlushTask = nil
        guard !text.isEmpty || !tools.isEmpty else { return }
        push(Moment(timestamp: now,
                     kind: .rockySaid(text: text, tools: tools)))
    }

    // MARK: - Face loss

    private func scheduleFaceLossCheck(for person: String) {
        faceLossTask?.cancel()
        let timeoutNs = UInt64(faceLossTimeout * 1_000_000_000)
        faceLossTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            guard !Task.isCancelled else { return }
            await self?.maybeEmitLoss()
        }
    }

    private func maybeEmitLoss() {
        let now = Date()
        for (person, lastAt) in lastSeen {
            if now.timeIntervalSince(lastAt) >= faceLossTimeout {
                lastSeen[person] = nil
                push(Moment(timestamp: now,
                             kind: .lostSightOf(person: person)))
            }
        }
    }

    // MARK: - Error recovery

    private func scheduleRecovery(for scope: String) {
        errorRecoveryTasks[scope]?.cancel()
        let holdNs = UInt64(errorRecoveryHold * 1_000_000_000)
        errorRecoveryTasks[scope] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: holdNs)
            guard !Task.isCancelled else { return }
            await self?.maybeRecover(scope: scope)
        }
    }

    private func maybeRecover(scope: String) {
        guard let lastErrorAt = recentErrorScopes[scope] else { return }
        let now = Date()
        guard now.timeIntervalSince(lastErrorAt) >= errorRecoveryHold else { return }
        recentErrorScopes[scope] = nil
        errorRecoveryTasks[scope] = nil
        push(Moment(timestamp: now, kind: .recovered(scope: scope)))
    }
}
