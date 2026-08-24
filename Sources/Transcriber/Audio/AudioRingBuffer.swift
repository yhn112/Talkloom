import Synchronization

/// A lock-free single-producer / single-consumer ring buffer of Float32 samples.
///
/// This is the hand-off between an audio callback and everything else. The producer is a
/// real-time thread — an `AudioDeviceIOProc` or an `AVAudioNodeTapBlock` — which may not
/// allocate, lock, or wait; the consumer is an ordinary task that resamples and writes to
/// disk. `write` and `read` therefore never block and never allocate, and the storage is
/// sized once, up front.
///
/// `@unchecked Sendable` is the exception `AGENTS.md` allows, and it rests on three
/// properties. The storage is allocated in `init` and freed in `deinit`, so its address
/// never changes while the buffer is alive — it is the raw pointer, not the cursors, that
/// the compiler cannot check. Exactly one thread calls `write` and exactly one calls
/// `read`, so each cursor has a single writer and needs no compare-and-exchange. The
/// cursors are exchanged with release/acquire ordering, which publishes the samples
/// written before the cursor moved. Calling `write` from two threads at once breaks all of
/// this.
final class AudioRingBuffer: @unchecked Sendable {
    /// Sample capacity, always a power of two so wrapping is a mask rather than a modulo.
    let capacity: Int

    private let storage: UnsafeMutablePointer<Float>
    private let mask: Int

    /// Total samples ever written and ever read. Both only increase; their difference is
    /// the fill level. Keeping them unwrapped is what makes "empty" and "full"
    /// distinguishable without sacrificing a slot.
    ///
    /// `Synchronization.Atomic` stores the value inline in this object, so there is nothing
    /// to allocate in `init` and nothing to destroy in `deinit`, and every operation is
    /// emitted into the caller — which is what an audio callback needs.
    private let writeCursor = Atomic<Int>(0)
    private let readCursor = Atomic<Int>(0)
    private let droppedCursor = Atomic<Int>(0)

    /// - Parameter capacity: minimum number of samples to hold; rounded up to a power of
    ///   two. Size it for the worst pause the consumer can take, not for one callback:
    ///   a second of 48 kHz stereo is 96 000 samples.
    init(capacity requestedCapacity: Int) {
        precondition(requestedCapacity > 0, "a ring buffer needs room for at least one sample")
        let capacity = requestedCapacity.roundedUpToPowerOfTwo
        self.capacity = capacity
        self.mask = capacity - 1
        self.storage = .allocate(capacity: capacity)
        self.storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Every sample the producer has ever written. Only ever increases, so a value that
    /// stops moving means the producer stopped — which is what a dead audio device looks
    /// like from this side, since nothing reports one.
    var totalSampleCount: Int { writeCursor.load(ordering: .acquiring) }

    /// Samples waiting to be read.
    var availableToRead: Int {
        writeCursor.load(ordering: .acquiring) - readCursor.load(ordering: .relaxed)
    }

    /// Samples the producer had to throw away because the consumer fell behind.
    ///
    /// Non-zero means the recording has holes in it, which is the one capture failure that
    /// still yields a plausible-looking file, so it is reported rather than swallowed.
    var droppedSampleCount: Int {
        droppedCursor.load(ordering: .relaxed)
    }

    /// Records samples the producer discarded before they ever reached the buffer.
    ///
    /// A block too large to be downmixed is lost just as surely as one that did not fit, and
    /// a hole in the recording should be counted the same way whichever end dropped it.
    func recordDrop(sampleCount: Int) {
        _ = droppedCursor.wrappingAdd(sampleCount, ordering: .relaxed)
    }

    /// Copies `count` samples in. Real-time safe: no allocation, no locks, no ARC.
    ///
    /// Returns `false` and drops the entire block when there is not enough room. Dropping
    /// whole blocks keeps the stream on frame boundaries — a partial write would shift the
    /// channels of an interleaved buffer against each other for the rest of the recording.
    @discardableResult
    func write(_ source: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return true }
        let writeIndex = writeCursor.load(ordering: .relaxed)
        let readIndex = readCursor.load(ordering: .acquiring)
        guard capacity - (writeIndex - readIndex) >= count else {
            _ = droppedCursor.wrappingAdd(count, ordering: .relaxed)
            return false
        }

        let offset = writeIndex & mask
        let firstChunk = min(count, capacity - offset)
        storage.advanced(by: offset).update(from: source, count: firstChunk)
        if firstChunk < count {
            storage.update(from: source.advanced(by: firstChunk), count: count - firstChunk)
        }

        writeCursor.store(writeIndex + count, ordering: .releasing)
        return true
    }

    /// Copies out up to `count` samples and returns how many were taken.
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let readIndex = readCursor.load(ordering: .relaxed)
        let writeIndex = writeCursor.load(ordering: .acquiring)
        let available = min(count, writeIndex - readIndex)
        guard available > 0 else { return 0 }

        let offset = readIndex & mask
        let firstChunk = min(available, capacity - offset)
        destination.update(from: storage.advanced(by: offset), count: firstChunk)
        if firstChunk < available {
            destination.advanced(by: firstChunk).update(
                from: storage, count: available - firstChunk)
        }

        readCursor.store(readIndex + available, ordering: .releasing)
        return available
    }
}

private extension Int {
    /// Rounds up to the next power of two, leaving exact powers of two alone.
    var roundedUpToPowerOfTwo: Int {
        guard self > 1 else { return 1 }
        return 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount)
    }
}
