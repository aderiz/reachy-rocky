import Foundation

/// Lock-free single-producer / single-consumer ring buffer for float32 audio.
///
/// `MicService` is the single producer (audio render thread); the VAD/STT
/// pipeline is the single consumer. Backpressure: when the buffer is full,
/// oldest samples are dropped and a counter increments — the dashboard can
/// surface the drop rate.
public final class AudioRingBuffer: @unchecked Sendable {
    private var storage: [Float]
    private let capacity: Int
    private var head: Int = 0     // write index
    private var tail: Int = 0     // read index
    private var count: Int = 0
    private let lock = NSLock()

    public private(set) var droppedSamples: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    public var availableSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Produce: append samples; drop oldest if full.
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        for s in samples {
            if count == capacity {
                tail = (tail + 1) % capacity
                count -= 1
                droppedSamples += 1
            }
            storage[head] = s
            head = (head + 1) % capacity
            count += 1
        }
    }

    /// Consume: copy up to `max` samples into `out`, return how many were copied.
    public func read(into out: inout [Float], max: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = Swift.min(max, count)
        out.removeAll(keepingCapacity: true)
        out.reserveCapacity(n)
        for _ in 0..<n {
            out.append(storage[tail])
            tail = (tail + 1) % capacity
        }
        count -= n
        return n
    }

    /// Convenience: drain everything currently buffered.
    public func drain() -> [Float] {
        var out: [Float] = []
        _ = read(into: &out, max: availableSamples)
        return out
    }
}
