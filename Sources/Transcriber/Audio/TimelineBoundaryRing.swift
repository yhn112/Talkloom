import Synchronization

/// The first accepted block after capture begins or a run of rejected blocks.
///
/// `sourceFrameOffset` counts accepted real samples only. `silentFrameCount` is what the
/// recorder must insert before the new span so the file keeps the producer's timeline.
struct TimelineBoundary: Equatable, Sendable {
    let sourceFrameOffset: Int
    let startHostTime: UInt64
    let silentFrameCount: Int
}

/// Preallocated SPSC handoff for the sparse boundaries that accompany the sample ring.
///
/// The same single callback that produces audio is the only writer, and the recorder actor
/// is the only reader. A boundary is release-published before the corresponding audio write
/// cursor; the consumer acquires the audio cursor before this cursor, so it cannot read
/// post-gap samples without first seeing their boundary. The raw storage never moves during
/// the buffer's lifetime.
final class TimelineBoundaryRing {
    private let storage: UnsafeMutablePointer<TimelineBoundary>
    private let capacity: Int
    private let mask: Int
    private let writeCursor = Atomic<Int>(0)
    private let readCursor = Atomic<Int>(0)

    init(capacity: Int) {
        precondition(capacity > 0 && capacity.nonzeroBitCount == 1)
        self.capacity = capacity
        self.mask = capacity - 1
        self.storage = .allocate(capacity: capacity)
        self.storage.initialize(
            repeating: TimelineBoundary(
                sourceFrameOffset: 0,
                startHostTime: 0,
                silentFrameCount: 0
            ),
            count: capacity
        )
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Producer-side preflight. The consumer can only create more room after this check.
    var canWrite: Bool {
        let writeIndex = writeCursor.load(ordering: .relaxed)
        let readIndex = readCursor.load(ordering: .acquiring)
        return writeIndex - readIndex < capacity
    }

    /// Publishes one boundary. Call only after `canWrite` succeeds.
    func write(_ boundary: TimelineBoundary) {
        let writeIndex = writeCursor.load(ordering: .relaxed)
        storage[writeIndex & mask] = boundary
        writeCursor.store(writeIndex + 1, ordering: .releasing)
    }

    /// Takes the next boundary, if the producer has published one.
    func read() -> TimelineBoundary? {
        let readIndex = readCursor.load(ordering: .relaxed)
        let writeIndex = writeCursor.load(ordering: .acquiring)
        guard readIndex < writeIndex else { return nil }

        let boundary = storage[readIndex & mask]
        readCursor.store(readIndex + 1, ordering: .releasing)
        return boundary
    }
}
