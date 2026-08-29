import Testing

@testable import Talkloom

@Suite("Audio ring buffer")
struct AudioRingBufferTests {
    /// Writes `count` samples counting up from `start`, so a later read can prove not just
    /// that samples arrived but that they arrived in order and unshifted.
    private func writeRamp(_ buffer: AudioRingBuffer, from start: Int, count: Int) -> Bool {
        let samples = (0..<count).map { Float(start + $0) }
        return samples.withUnsafeBufferPointer { buffer.write($0.baseAddress!, count: count) }
    }

    private func readAll(_ buffer: AudioRingBuffer, count: Int) -> [Float] {
        var out = [Float](repeating: .nan, count: count)
        let read = out.withUnsafeMutableBufferPointer {
            buffer.read(into: $0.baseAddress!, count: count)
        }
        return Array(out.prefix(read))
    }

    @Test(
        "capacity is rounded up to a power of two",
        arguments: [(1000, 1024), (1024, 1024), (1025, 2048)]
    )
    func capacityIsRoundedUp(requested: Int, expected: Int) {
        #expect(AudioRingBuffer(capacity: requested).capacity == expected)
    }

    @Test("samples come back in order")
    func samplesComeBackInOrder() {
        let buffer = AudioRingBuffer(capacity: 64)
        #expect(writeRamp(buffer, from: 0, count: 10))

        #expect(buffer.availableToRead == 10)
        #expect(readAll(buffer, count: 10) == (0..<10).map(Float.init))
        #expect(buffer.availableToRead == 0)
    }

    @Test("a read of an empty buffer takes nothing")
    func readOfAnEmptyBufferTakesNothing() {
        #expect(readAll(AudioRingBuffer(capacity: 64), count: 16) == [])
    }

    /// The case that silently corrupts a recording: a block that straddles the end of the
    /// storage has to be copied in two pieces, and getting the second piece wrong shows up
    /// as a periodic click rather than as an error.
    @Test("writes and reads wrap around")
    func writesAndReadsWrapAround() {
        let buffer = AudioRingBuffer(capacity: 16)

        // Move the cursors close to the end of the storage, then straddle it.
        #expect(writeRamp(buffer, from: 0, count: 12))
        #expect(readAll(buffer, count: 12).count == 12)
        #expect(writeRamp(buffer, from: 100, count: 10))

        #expect(readAll(buffer, count: 10) == (100..<110).map(Float.init))
    }

    @Test("many wraps preserve order")
    func manyWrapsPreserveOrder() {
        let buffer = AudioRingBuffer(capacity: 16)
        var expected = 0

        for round in 0..<50 {
            let count = 1 + round % 7
            #expect(writeRamp(buffer, from: expected, count: count))
            #expect(
                readAll(buffer, count: count) == (expected..<(expected + count)).map(Float.init))
            expected += count
        }
        #expect(buffer.droppedSampleCount == 0)
    }

    /// A full buffer must refuse the whole block. A partial write would shift the channels
    /// of an interleaved stream against each other for the rest of the recording.
    @Test("overflow drops the whole block and is counted")
    func overflowDropsTheWholeBlock() {
        let buffer = AudioRingBuffer(capacity: 16)
        #expect(writeRamp(buffer, from: 0, count: 16))

        #expect(!writeRamp(buffer, from: 1000, count: 4))
        #expect(buffer.droppedSampleCount == 4)
        #expect(buffer.availableToRead == 16)
        #expect(readAll(buffer, count: 16) == (0..<16).map(Float.init))
    }

    @Test("writing exactly to capacity succeeds")
    func writingExactlyToCapacitySucceeds() {
        let buffer = AudioRingBuffer(capacity: 16)
        #expect(writeRamp(buffer, from: 0, count: 16))
        #expect(buffer.availableToRead == 16)
        #expect(buffer.droppedSampleCount == 0)
    }

    @Test("a read accepts more than is available")
    func readAcceptsMoreThanIsAvailable() {
        let buffer = AudioRingBuffer(capacity: 64)
        #expect(writeRamp(buffer, from: 0, count: 5))
        #expect(readAll(buffer, count: 64) == (0..<5).map(Float.init))
    }

    /// The buffer's whole purpose is one producer thread and one consumer thread running at
    /// once. This drives both concurrently and checks the consumer sees a gap-free ramp —
    /// the failure mode being torn or reordered blocks, not a crash.
    ///
    /// Child tasks of a group rather than detached ones or dispatch queues: an expectation
    /// has to be recorded from within the test's task tree to be attributed to this test at
    /// all, and a detached task is outside it.
    @Test("a concurrent producer and consumer see a gap-free stream", .timeLimit(.minutes(1)))
    func concurrentProducerAndConsumerSeeAGapFreeStream() async {
        let buffer = AudioRingBuffer(capacity: 1024)
        let blockSize = 64
        let blockCount = 2000

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var next: Float = 0
                var scratch = [Float](repeating: 0, count: blockSize)
                var received = 0

                while received < blockCount * blockSize {
                    let read = scratch.withUnsafeMutableBufferPointer {
                        buffer.read(into: $0.baseAddress!, count: blockSize)
                    }
                    for index in 0..<read {
                        #expect(scratch[index] == next)
                        next += 1
                    }
                    received += read
                    if read == 0 { await Task.yield() }
                }
            }

            group.addTask {
                var sample = 0
                for _ in 0..<blockCount {
                    let block = (0..<blockSize).map { Float(sample + $0) }
                    // The producer is the real-time side and may not wait, but the test
                    // must not lose samples, so it retries instead of dropping. Every
                    // refused attempt still counts as a drop, so `droppedSampleCount` says
                    // nothing here — what is checked is that the consumer saw every sample
                    // exactly once, in order.
                    while !block.withUnsafeBufferPointer({
                        buffer.write($0.baseAddress!, count: blockSize)
                    }) {
                        await Task.yield()
                    }
                    sample += blockSize
                }
            }
        }
    }
}
