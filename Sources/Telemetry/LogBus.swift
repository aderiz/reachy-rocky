import Foundation

/// Single multicast publisher for every `TelemetryEvent` Rocky generates.
///
/// Subscribers receive events through an `AsyncStream`. Each call to `subscribe()`
/// returns a fresh stream backed by its own buffer; the actor fans events out
/// without blocking the publisher.
public actor LogBus {
    private var continuations: [UUID: AsyncStream<TimestampedEvent>.Continuation] = [:]

    public init() {}

    /// Publish an event to every active subscriber. Non-blocking.
    public func publish(_ event: TelemetryEvent, at timestamp: Date = .init()) {
        let stamped = TimestampedEvent(timestamp: timestamp, event: event)
        for cont in continuations.values {
            cont.yield(stamped)
        }
    }

    /// Subscribe to the stream of events. Cancel the returned task to detach.
    ///
    /// Eagerly registers the continuation BEFORE returning, so events
    /// published between the caller's `await bus.subscribe()` and the
    /// start of their `for await` loop land in the stream's buffer
    /// instead of being dropped. The previous implementation used the
    /// `AsyncStream { build in ... }` initialiser, whose `build`
    /// closure only runs lazily on first iteration — long sidecar
    /// startups (the brain's load+warmup window) would fire log
    /// events into a still-empty `continuations` dictionary and the
    /// subscriber would only ever see post-startup events. That's
    /// why the warmup-phase health viz never lit up: every
    /// `phase=load_start|load_done|warm_done` event fired into the
    /// void before the pump's `for await` began.
    public func subscribe(bufferSize: Int = 256) -> AsyncStream<TimestampedEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TimestampedEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferSize)
        )
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.detach(id: id) }
        }
        return stream
    }

    private func detach(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
