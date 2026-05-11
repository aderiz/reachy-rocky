import Foundation
import Telemetry

/// Concrete `Sidecar` conformer: owns a `Process`, three pipes, and the
/// request/stream correlation tables.
///
/// Lifecycle:
///   stopped → starting (spawn) → ready (after `ready` event) → ready / failing → stopped
///
/// Restart policy is enforced by `SidecarSupervisor` watching `outboundEvents`.
public actor SidecarRuntime: Sidecar {
    // MARK: - Public

    public nonisolated let name: String
    public nonisolated let manifest: SidecarManifest
    public var state: SidecarState { _state }

    /// Multicast event source. Each call returns a fresh
    /// `AsyncStream` subscribed to a single internal broadcast point;
    /// every emitted event is delivered to every active subscriber in
    /// order. Supports the supervisor watcher, the per-sidecar Swift
    /// service (e.g. `RobotMicService`), and any AppServices mirror
    /// listening for state transitions — all simultaneously.
    ///
    /// Single-consumer behaviour was the root cause of the mic stall
    /// loop on 2026-05-08: supervisor and `RobotMicService` were
    /// racing for the same `AsyncStream`, so `.state(.failing)` and
    /// `.state(.ready)` events landed unpredictably and either the
    /// restart never fired or the new sidecar never got
    /// `start_recording` re-issued.
    ///
    /// Subscriber registration runs synchronously inside the actor
    /// (the call is `async` and inserts the continuation before
    /// returning), so events emitted between `subscribe()` returning
    /// and the consumer's first iteration are NOT lost. The
    /// non-throwing `events` property keeps the older synchronous
    /// API for code paths that can tolerate the brief insertion
    /// race; new code should prefer `subscribe()`.
    public func subscribe() -> AsyncStream<SidecarOutboundEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let id = UUID()
            // Synchronous insert — we're already on the actor.
            self.subscribers[id] = continuation
            continuation.yield(.state(self._state))
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeSubscriber(id: id)
                }
            }
        }
    }

    public nonisolated var events: AsyncStream<SidecarOutboundEvent> {
        // Bridge to the actor-isolated `subscribe()` for callsites
        // that haven't migrated. There is a small window between this
        // returning and the Task running where state-only events can
        // land in the buffer (state replay handles `.state`); for
        // exact-ordering guarantees use `subscribe()`.
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let id = UUID()
            Task { [weak self] in
                await self?.addSubscriber(id: id, continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeSubscriber(id: id)
                }
            }
        }
    }

    // MARK: - Internals

    private let resolver: ManifestPathResolver
    private let logBus: LogBus
    private let codec = JSONLineCodec()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    private var _state: SidecarState = .stopped {
        didSet { emit(.state(_state)) }
    }

    private var subscribers: [UUID: AsyncStream<SidecarOutboundEvent>.Continuation] = [:]

    /// `id` → continuation expecting a single envelope.
    private var pending: [String: PendingRequest] = [:]
    /// `id` → stream continuation expecting many chunks ending in stream_end.
    private var streams: [String: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private var nextRequestId: UInt64 = 0

    private var readyContinuation: CheckedContinuation<Void, Error>?

    // Restart bookkeeping (the supervisor calls `markRestart` and queries
    // `shouldCircuitBreak`).
    private var restartTimestamps: [Date] = []

    public init(manifest: SidecarManifest, resolver: ManifestPathResolver, logBus: LogBus) {
        self.name = manifest.name
        self.manifest = manifest
        self.resolver = resolver
        self.logBus = logBus
    }

    private func addSubscriber(
        id: UUID,
        continuation: AsyncStream<SidecarOutboundEvent>.Continuation
    ) {
        subscribers[id] = continuation
        // Replay the current state so a late subscriber doesn't miss
        // a `.ready` transition that fired before it connected. State
        // is a CURRENT-VALUE concept (the sidecar is `.ready` right
        // now), unlike `.event` / `.log` which are transient
        // notifications — those rightly only flow forward from the
        // moment of subscription. Without this replay, AppServices'
        // state mirror was reading `.stopped` forever even after the
        // sidecar reached `.ready`, because its subscription happens
        // immediately AFTER `sidecar.start()` returns.
        continuation.yield(.state(_state))
    }

    private func removeSubscriber(id: UUID) {
        subscribers[id]?.finish()
        subscribers.removeValue(forKey: id)
    }

    /// Broadcast an event to every active subscriber. Yielding to an
    /// `AsyncStream.Continuation` is non-blocking and Sendable-safe,
    /// so this is fine to call from inside a `didSet` or any
    /// actor-isolated method.
    private func emit(_ event: SidecarOutboundEvent) {
        for cont in subscribers.values {
            cont.yield(event)
        }
    }

    // MARK: - Sidecar API

    public func start() async throws {
        switch _state {
        case .ready, .starting: throw SidecarError.alreadyRunning
        default: break
        }

        _state = .starting
        try await spawn()
        try await awaitReady()
        _state = .ready
    }

    public func stop() async {
        guard let process else { return }

        // SIGTERM, give it `shutdownGraceS`, then SIGKILL.
        kill(process.processIdentifier, SIGTERM)
        let deadline = Date().addingTimeInterval(manifest.shutdownGraceS)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }

        await cleanupAfterExit(reason: "stopped")
        _state = .stopped
    }

    public func send<R: Decodable & Sendable>(
        method: String,
        params: any Encodable & Sendable
    ) async throws -> R {
        let id = newRequestId()
        let timeout = manifest.timeout(forMethod: method)

        return try await withThrowingTaskGroup(of: R.self) { group in
            group.addTask {
                try await self.awaitResponse(id: id, decoder: JSONDecoder(), as: R.self)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SidecarError.methodTimeout(method: method, after: timeout)
            }
            try writeRequest(id: id, method: method, params: params)
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    public nonisolated func stream(
        method: String,
        params: any Encodable & Sendable
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream<Data, Error> { continuation in
            Task { await self.beginStream(method: method, params: params, continuation: continuation) }
        }
    }

    // MARK: - Restart bookkeeping (used by supervisor)

    public func markRestartAttempt() {
        restartTimestamps.append(Date())
        let cutoff = Date().addingTimeInterval(-60)
        restartTimestamps.removeAll { $0 < cutoff }
    }

    public func shouldCircuitBreak() -> Bool {
        restartTimestamps.count > manifest.restartMaxPerMinute
    }

    public func enterCircuitBreak(cooldownS: Double) {
        _state = .circuitOpen(cooldownUntil: Date().addingTimeInterval(cooldownS))
    }

    // MARK: - Spawn / read loops

    private func spawn() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: resolver.resolve(manifest.binary))
        p.arguments = resolver.resolve(manifest.args)
        p.currentDirectoryURL = URL(fileURLWithPath: resolver.resolve(manifest.workingDir))
        var env = ProcessInfo.processInfo.environment
        for (k, v) in manifest.env { env[k] = v }
        p.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        // Drain stdout: parse envelopes.
        let stdoutHandle = stdout.fileHandleForReading
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { await self.ingestStdout(data) }
        }

        // Drain stderr: tag and forward as logs.
        let stderrHandle = stderr.fileHandleForReading
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { await self.ingestStderr(data) }
        }

        // Watch for exit.
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task {
                let reason = "exit code \(proc.terminationStatus), reason \(proc.terminationReason.rawValue)"
                await self.handleExit(reason: reason)
            }
        }

        try p.run()
        self.process = p
        self.stdinHandle = stdin.fileHandleForWriting
    }

    private func awaitReady() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.readyContinuation = cont
            Task {
                try? await Task.sleep(nanoseconds: UInt64(manifest.readyTimeoutS * 1_000_000_000))
                self.failReadyIfPending()
            }
        }
    }

    private func failReadyIfPending() {
        guard let cont = readyContinuation else { return }
        readyContinuation = nil
        cont.resume(throwing: SidecarError.readyTimeout)
        _state = .failing(reason: "ready timeout")
    }

    // MARK: - Ingest

    private func ingestStdout(_ chunk: Data) async {
        // The codec now downgrades non-JSON lines into `.log`
        // envelopes itself (Python sidecars print status to stdout,
        // and we don't want every print() to fire a decode error
        // that drops the rest of the batch).
        let envelopes = codec.consume(chunk, into: &stdoutBuffer)
        for env in envelopes {
            await dispatch(env)
        }
    }

    private func ingestStderr(_ chunk: Data) async {
        stderrBuffer.append(chunk)
        while let nl = stderrBuffer.firstIndex(of: 0x0A) {
            let line = stderrBuffer.prefix(upTo: nl)
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...nl)
            let text = String(data: line, encoding: .utf8) ?? ""
            if !text.isEmpty {
                // Mirror to the parent's stderr so Console.app /
                // terminal launches can see sidecar diagnostic
                // output (e.g. brain's chat_stream traces) without
                // having to open the in-app Logs view.
                let prefixed = "[sidecar:\(name)] \(text)\n"
                if let data = prefixed.data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
                await logBus.publish(.sidecarLog(
                    sidecar: name, level: .info, message: text, fields: ["stream": "stderr"]
                ))
                emit(.log(level: .info, message: text, fields: ["stream": "stderr"]))
            }
        }
    }

    private func dispatch(_ envelope: JSONLineCodec.Envelope) async {
        switch envelope {
        case .response(let id, let result):
            if let waiter = pending.removeValue(forKey: id) {
                waiter.resume(.success(result))
            }
        case .error(let id, let code, let message):
            if let waiter = pending.removeValue(forKey: id) {
                waiter.resume(.failure(SidecarError.crashed(reason: "code=\(code) \(message)")))
            }
            if let stream = streams.removeValue(forKey: id) {
                stream.finish(throwing: SidecarError.crashed(reason: "code=\(code) \(message)"))
            }
        case .streamChunk(let id, let data):
            streams[id]?.yield(data)
        case .streamEnd(let id):
            streams.removeValue(forKey: id)?.finish()
        case .event(let evName, let payload):
            if evName == manifest.readyEvent, let cont = readyContinuation {
                readyContinuation = nil
                cont.resume(returning: ())
            }
            await logBus.publish(.sidecarLog(
                sidecar: name, level: .debug,
                message: "event \(evName)",
                fields: ["payload_bytes": "\(payload.count)"]
            ))
            emit(.event(name: evName, payload: payload))
        case .log(let level, let message, let fields):
            let lvl = TelemetryEvent.LogLevel(rawValue: level) ?? .info
            await logBus.publish(.sidecarLog(sidecar: name, level: lvl, message: message, fields: fields))
            emit(.log(level: lvl, message: message, fields: fields))
        case .unknown(let raw):
            let preview = String(data: raw.prefix(120), encoding: .utf8) ?? ""
            await logBus.publish(.error(
                scope: "sidecar:\(name)",
                message: "unknown envelope: \(preview)",
                recoverable: true
            ))
        }
    }

    private func handleExit(reason: String) async {
        await cleanupAfterExit(reason: reason)
        _state = .failing(reason: reason)
    }

    private func cleanupAfterExit(reason: String) async {
        // Cancel any pending requests/streams.
        for (_, p) in pending { p.resume(.failure(SidecarError.crashed(reason: reason))) }
        pending.removeAll()
        for (_, s) in streams { s.finish(throwing: SidecarError.crashed(reason: reason)) }
        streams.removeAll()

        // Drop the process; release pipes.
        process = nil
        stdinHandle = nil
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()

        if let ready = readyContinuation {
            readyContinuation = nil
            ready.resume(throwing: SidecarError.crashed(reason: reason))
        }
    }

    // MARK: - Request bookkeeping

    private func newRequestId() -> String {
        nextRequestId &+= 1
        return "r-\(nextRequestId)"
    }

    private func writeRequest(id: String, method: String, params: any Encodable & Sendable) throws {
        guard let stdin = stdinHandle else { throw SidecarError.notReady }
        let line = try codec.encodeRequest(id: id, method: method, params: AnyEncodable(params))
        try stdin.write(contentsOf: line)
    }

    private func awaitResponse<R: Decodable & Sendable>(
        id: String,
        decoder: JSONDecoder,
        as type: R.Type
    ) async throws -> R {
        let data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            pending[id] = PendingRequest { result in
                switch result {
                case .success(let data): cont.resume(returning: data)
                case .failure(let err):  cont.resume(throwing: err)
                }
            }
        }
        do { return try decoder.decode(R.self, from: data) }
        catch { throw SidecarError.decode(message: "\(error)") }
    }

    private func beginStream(
        method: String,
        params: any Encodable & Sendable,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        let id = newRequestId()
        streams[id] = continuation
        do {
            try writeRequest(id: id, method: method, params: params)
        } catch {
            streams.removeValue(forKey: id)
            continuation.finish(throwing: error)
        }
    }

    // Erase Encodable so we can pass mixed payloads through the codec.
    private struct AnyEncodable: Encodable {
        let value: any Encodable
        init(_ value: any Encodable) { self.value = value }
        func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
    }

    private struct PendingRequest {
        let resume: @Sendable (Result<Data, Error>) -> Void
    }
}
