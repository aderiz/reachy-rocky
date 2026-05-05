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
    public func subscribe(bufferSize: Int = 256) -> AsyncStream<TimestampedEvent> {
        let id = UUID()
        return AsyncStream<TimestampedEvent>(
            bufferingPolicy: .bufferingNewest(bufferSize)
        ) { continuation in
            self.attach(id: id, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.detach(id: id) }
            }
        }
    }

    private func attach(id: UUID, continuation: AsyncStream<TimestampedEvent>.Continuation) {
        continuations[id] = continuation
    }

    private func detach(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
