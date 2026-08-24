import XCTest

@testable import Transcriber

final class AudioRingBufferTests: XCTestCase {
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

    func testCapacityIsRoundedUpToAPowerOfTwo() {
        XCTAssertEqual(AudioRingBuffer(capacity: 1000).capacity, 1024)
        XCTAssertEqual(AudioRingBuffer(capacity: 1024).capacity, 1024)
        XCTAssertEqual(AudioRingBuffer(capacity: 1025).capacity, 2048)
    }

    func testSamplesComeBackInOrder() {
        let buffer = AudioRingBuffer(capacity: 64)
        XCTAssertTrue(writeRamp(buffer, from: 0, count: 10))

        XCTAssertEqual(buffer.availableToRead, 10)
        XCTAssertEqual(readAll(buffer, count: 10), (0..<10).map(Float.init))
        XCTAssertEqual(buffer.availableToRead, 0)
    }

    func testReadOfAnEmptyBufferTakesNothing() {
        let buffer = AudioRingBuffer(capacity: 64)
        XCTAssertEqual(readAll(buffer, count: 16), [])
    }

    /// The case that silently corrupts a recording: a block that straddles the end of the
    /// storage has to be copied in two pieces, and getting the second piece wrong shows up
    /// as a periodic click rather than as an error.
    func testWritesAndReadsWrapAround() {
        let buffer = AudioRingBuffer(capacity: 16)

        // Move the cursors close to the end of the storage, then straddle it.
        XCTAssertTrue(writeRamp(buffer, from: 0, count: 12))
        XCTAssertEqual(readAll(buffer, count: 12).count, 12)
        XCTAssertTrue(writeRamp(buffer, from: 100, count: 10))

        XCTAssertEqual(readAll(buffer, count: 10), (100..<110).map(Float.init))
    }

    func testManyWrapsPreserveOrder() {
        let buffer = AudioRingBuffer(capacity: 16)
        var expected = 0

        for round in 0..<50 {
            let count = 1 + round % 7
            XCTAssertTrue(writeRamp(buffer, from: expected, count: count))
            XCTAssertEqual(
                readAll(buffer, count: count), (expected..<(expected + count)).map(Float.init))
            expected += count
        }
        XCTAssertEqual(buffer.droppedSampleCount, 0)
    }

    /// A full buffer must refuse the whole block. A partial write would shift the channels
    /// of an interleaved stream against each other for the rest of the recording.
    func testOverflowDropsTheWholeBlockAndIsCounted() {
        let buffer = AudioRingBuffer(capacity: 16)
        XCTAssertTrue(writeRamp(buffer, from: 0, count: 16))

        XCTAssertFalse(writeRamp(buffer, from: 1000, count: 4))
        XCTAssertEqual(buffer.droppedSampleCount, 4)
        XCTAssertEqual(buffer.availableToRead, 16)
        XCTAssertEqual(readAll(buffer, count: 16), (0..<16).map(Float.init))
    }

    func testWritingExactlyToCapacitySucceeds() {
        let buffer = AudioRingBuffer(capacity: 16)
        XCTAssertTrue(writeRamp(buffer, from: 0, count: 16))
        XCTAssertEqual(buffer.availableToRead, 16)
        XCTAssertEqual(buffer.droppedSampleCount, 0)
    }

    func testReadAcceptsMoreThanIsAvailable() {
        let buffer = AudioRingBuffer(capacity: 64)
        XCTAssertTrue(writeRamp(buffer, from: 0, count: 5))
        XCTAssertEqual(readAll(buffer, count: 64), (0..<5).map(Float.init))
    }

    /// The buffer's whole purpose is one producer thread and one consumer thread running at
    /// once. This drives both concurrently and checks the consumer sees a gap-free ramp —
    /// the failure mode being torn or reordered blocks, not a crash.
    func testConcurrentProducerAndConsumerSeeAGapFreeStream() {
        let buffer = AudioRingBuffer(capacity: 1024)
        let blockSize = 64
        let blockCount = 2000
        let finished = expectation(description: "consumer drained the stream")

        DispatchQueue.global().async {
            var next: Float = 0
            var scratch = [Float](repeating: 0, count: blockSize)
            var received = 0

            while received < blockCount * blockSize {
                let read = scratch.withUnsafeMutableBufferPointer {
                    buffer.read(into: $0.baseAddress!, count: blockSize)
                }
                for index in 0..<read {
                    XCTAssertEqual(scratch[index], next)
                    next += 1
                }
                received += read
            }
            finished.fulfill()
        }

        DispatchQueue.global().async {
            var sample = 0
            for _ in 0..<blockCount {
                let block = (0..<blockSize).map { Float(sample + $0) }
                // The producer is the real-time side and may not wait, but the test must
                // not lose samples, so it retries instead of dropping.
                while !block.withUnsafeBufferPointer({
                    buffer.write($0.baseAddress!, count: blockSize)
                }) {
                    Thread.sleep(forTimeInterval: 0.0005)
                }
                sample += blockSize
            }
        }

        wait(for: [finished], timeout: 30)
    }
}
