import Testing
import Voice

@Suite("AudioRingBuffer")
struct AudioRingBufferTests {
    @Test("write then read returns same samples")
    func roundTrip() {
        let rb = AudioRingBuffer(capacity: 8)
        var input: [Float] = [0.1, 0.2, 0.3, 0.4]
        input.withUnsafeBufferPointer { rb.write($0) }
        var out: [Float] = []
        let n = rb.read(into: &out, max: 4)
        #expect(n == 4)
        #expect(out == input)
    }

    @Test("write past capacity drops oldest samples")
    func overflowDropsOldest() {
        let rb = AudioRingBuffer(capacity: 4)
        var input: [Float] = [1, 2, 3, 4, 5, 6]
        input.withUnsafeBufferPointer { rb.write($0) }
        let drained = rb.drain()
        #expect(drained == [3, 4, 5, 6])
        #expect(rb.droppedSamples == 2)
    }

    @Test("partial reads advance the tail")
    func partialReads() {
        let rb = AudioRingBuffer(capacity: 8)
        var input: [Float] = [1, 2, 3, 4, 5, 6]
        input.withUnsafeBufferPointer { rb.write($0) }
        var out: [Float] = []
        _ = rb.read(into: &out, max: 3)
        #expect(out == [1, 2, 3])
        _ = rb.read(into: &out, max: 5)
        #expect(out == [4, 5, 6])
    }
}
