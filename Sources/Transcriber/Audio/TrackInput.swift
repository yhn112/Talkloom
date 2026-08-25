import AVFoundation
import CoreAudio
import Synchronization

/// The producer's end of one recorded track — everything an audio callback is allowed to
/// touch, and nothing else.
///
/// Real-time safe by construction: a scratch buffer allocated once in `init`, a downmix
/// that is a bounded loop over the block, and a lock-free ring buffer. No allocation, no
/// locks, no file I/O, no `await`.
///
/// The downmix happens here, on the real-time side, because the master is mono in the
/// source sample rate. Resampling happens only after the finished file is closed.
///
/// `@unchecked Sendable`: the ring buffer carries its own justification, and `scratch` is
/// allocated in `init`, freed in `deinit`, and only ever touched by the single audio thread
/// that calls `write`.
final class TrackInput: @unchecked Sendable {
    let ring: AudioRingBuffer

    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int
    private let boundaries: TimelineBoundaryRing

    /// Producer-only state. The callback is the single writer required by the SPSC rings,
    /// so these values need no synchronization and must never be touched by the consumer.
    private var needsBoundary = true
    private var pendingDroppedFrameCount = 0

    /// The recorder reads these from its actor while the callback may still be running.
    private let didObserveTimeline = Atomic<Bool>(false)
    private let timelineIsComplete = Atomic<Bool>(true)

    /// Mach host time represented by frame zero of the master, or 0 if none has arrived.
    ///
    /// This is the track's time origin, and it is recorded rather than assumed. Both
    /// capture paths hand over a mach timestamp taken by the audio hardware, and mach time
    /// is one clock for the whole machine — so the microphone and the system tap can be
    /// lined up against each other exactly, however far apart they happened to start.
    private let firstHostTime = Atomic<UInt64>(0)

    /// Shape of the most recent block — buffer count, channels in the first buffer, and its
    /// size — kept for diagnosing a track whose length does not match the wall clock.
    private let lastListShape = Atomic<UInt64>(0)

    /// Blocks refused because the buffer list was not the single buffer expected.
    private let unexpectedLayouts = Atomic<Int>(0)

    /// - Parameters:
    ///   - ringCapacity: samples of headroom for the consumer, at the *source* sample rate.
    ///   - maximumFrameCount: largest block a callback may hand over. A larger block is
    ///     dropped rather than truncated, so size it generously.
    init(ringCapacity: Int, maximumFrameCount: Int = 16_384) {
        ring = AudioRingBuffer(capacity: ringCapacity)
        // One boundary needs at least one accepted sample before another can follow. Giving
        // the sparse side ring the sample ring's capacity therefore makes metadata capacity
        // at least as large as the number of unresolved boundaries it can accompany.
        boundaries = TimelineBoundaryRing(capacity: ring.capacity)
        scratchCapacity = maximumFrameCount
        scratch = .allocate(capacity: maximumFrameCount)
        scratch.initialize(repeating: 0, count: maximumFrameCount)
    }

    deinit {
        scratch.deinitialize(count: scratchCapacity)
        scratch.deallocate()
    }

    /// How many blocks were refused for arriving in an unexpected buffer layout.
    var unexpectedLayoutCount: Int { unexpectedLayouts.load(ordering: .relaxed) }

    /// Buffer count, channel count and byte size of the last block received.
    var lastBufferListShape: (buffers: Int, channels: Int, byteCount: Int) {
        let shape = lastListShape.load(ordering: .relaxed)
        return (Int(shape >> 48), Int((shape >> 32) & 0xFFFF), Int(shape & 0xFFFF_FFFF))
    }

    /// Hardware time represented by frame zero, or `nil` if the timeline is unknown.
    var firstSampleHostTime: UInt64? {
        guard hasCompleteTimeline else { return nil }
        let value = firstHostTime.load(ordering: .relaxed)
        return value == 0 ? nil : value
    }

    /// Whether every written or replaced block had a hardware anchor and the drop counter
    /// remained representable. Direct access to `ring` is deliberately treated as unknown.
    var hasCompleteTimeline: Bool {
        didObserveTimeline.load(ordering: .relaxed)
            && timelineIsComplete.load(ordering: .relaxed)
    }

    /// Consumer-side boundary read. The recorder first acquires the audio write cursor, then
    /// calls this, matching the producer's boundary-before-audio publication order.
    func readBoundary() -> TimelineBoundary? { boundaries.read() }

    /// Any final rejected blocks after the last accepted span. The producer must already be
    /// stopped before the recorder asks for this value.
    func terminalDroppedFrameCount() -> Int { pendingDroppedFrameCount }

    /// Samples the producer had to throw away, either because the consumer fell behind or
    /// because a block was larger than the scratch buffer.
    var droppedSampleCount: Int { ring.droppedSampleCount }

    /// Accepts a block from an `AVAudioNodeTapBlock`.
    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer, atHostTime hostTime: UInt64? = nil) -> Bool {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channels = buffer.floatChannelData else { return true }

        let channelCount = Int(buffer.format.channelCount)
        if buffer.format.isInterleaved {
            return write(
                interleaved: channels[0],
                frameCount: frameCount,
                channelCount: channelCount,
                hostTime: hostTime
            )
        }
        return write(
            deinterleaved: channels,
            frameCount: frameCount,
            channelCount: channelCount,
            hostTime: hostTime
        )
    }

    /// Accepts a block from an `AudioDeviceIOBlock`.
    ///
    /// Exactly one buffer is expected, and the expectation is enforced rather than worked
    /// around. More than one means the device is delivering streams the caller never asked
    /// for, and nothing in the list reliably says which of them is the wanted one —
    /// measured against an aggregate holding both a process tap and an output device: two
    /// buffers, the first carrying six channels of the device rather than the tap. Reading
    /// it as one stream scaled the track's length by six and filled it with the wrong
    /// audio, and neither showed up as an error anywhere. Refusing the block instead turns
    /// a misconfigured device into missing samples, which is counted and visible.
    @discardableResult
    func write(
        _ bufferList: UnsafePointer<AudioBufferList>,
        atHostTime hostTime: UInt64? = nil
    ) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first else { return true }

        lastListShape.store(
            UInt64(buffers.count) << 48 | UInt64(first.mNumberChannels) << 32
                | UInt64(first.mDataByteSize),
            ordering: .relaxed
        )

        let channelCount = Int(first.mNumberChannels)
        guard buffers.count == 1, channelCount > 0, let data = first.mData else {
            _ = unexpectedLayouts.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        guard first.mDataByteSize > 0 else { return true }

        return write(
            interleaved: data.assumingMemoryBound(to: Float.self),
            frameCount: Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channelCount),
            channelCount: channelCount,
            hostTime: hostTime
        )
    }

    /// Accepts already-mono samples. Used by deterministic tests and by the downmix paths.
    @discardableResult
    func write(
        _ samples: UnsafePointer<Float>,
        count: Int,
        atHostTime hostTime: UInt64?
    ) -> Bool {
        writeMono(samples, frameCount: count, hostTime: hostTime)
    }

    private func write(
        interleaved samples: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        hostTime: UInt64?
    ) -> Bool {
        guard frameCount > 0 else { return true }
        guard channelCount > 1 else {
            return writeMono(samples, frameCount: frameCount, hostTime: hostTime)
        }
        guard frameCount <= scratchCapacity else {
            recordDrop(frameCount: frameCount, hostTime: hostTime)
            return false
        }

        let scale = 1 / Float(channelCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += samples[frame * channelCount + channel]
            }
            scratch[frame] = sum * scale
        }
        return writeMono(scratch, frameCount: frameCount, hostTime: hostTime)
    }

    private func write(
        deinterleaved channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        channelCount: Int,
        hostTime: UInt64?
    ) -> Bool {
        guard channelCount > 1 else {
            return writeMono(channels[0], frameCount: frameCount, hostTime: hostTime)
        }
        guard frameCount <= scratchCapacity else {
            recordDrop(frameCount: frameCount, hostTime: hostTime)
            return false
        }

        scratch.update(from: channels[0], count: frameCount)
        for channel in 1..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                scratch[frame] += samples[frame]
            }
        }
        let scale = 1 / Float(channelCount)
        for frame in 0..<frameCount {
            scratch[frame] *= scale
        }
        return writeMono(scratch, frameCount: frameCount, hostTime: hostTime)
    }

    /// Publishes a span boundary before the first accepted block in that span, then the
    /// samples. The consumer acquires those cursors in the opposite order, so it cannot read
    /// across a gap before seeing the boundary that describes it.
    private func writeMono(
        _ samples: UnsafePointer<Float>,
        frameCount: Int,
        hostTime: UInt64?
    ) -> Bool {
        guard frameCount > 0 else { return true }
        didObserveTimeline.store(true, ordering: .relaxed)
        let validHostTime = hostTime.flatMap { $0 == 0 ? nil : $0 }
        if validHostTime == nil { timelineIsComplete.store(false, ordering: .relaxed) }

        guard ring.canWrite(sampleCount: frameCount) else {
            recordDrop(frameCount: frameCount, hostTime: validHostTime)
            return false
        }
        guard !needsBoundary || boundaries.canWrite else {
            recordDrop(frameCount: frameCount, hostTime: validHostTime)
            return false
        }

        if needsBoundary {
            boundaries.write(
                TimelineBoundary(
                    sourceFrameOffset: ring.totalSampleCount,
                    startHostTime: validHostTime ?? 0,
                    silentFrameCount: pendingDroppedFrameCount
                ))
        }

        // The preflight cannot become false: this is the only producer, and the consumer can
        // only free room. A failure here would mean the SPSC contract was violated.
        precondition(ring.write(samples, count: frameCount))

        if let validHostTime, timelineIsComplete.load(ordering: .relaxed) {
            _ = firstHostTime.compareExchange(
                expected: 0, desired: validHostTime, ordering: .relaxed)
        }
        needsBoundary = false
        pendingDroppedFrameCount = 0
        return true
    }

    private func recordDrop(frameCount: Int, hostTime: UInt64?) {
        didObserveTimeline.store(true, ordering: .relaxed)
        if hostTime == nil { timelineIsComplete.store(false, ordering: .relaxed) }
        if let hostTime, timelineIsComplete.load(ordering: .relaxed) {
            _ = firstHostTime.compareExchange(
                expected: 0, desired: hostTime, ordering: .relaxed)
        }
        ring.recordDrop(sampleCount: frameCount)
        let (total, overflow) = pendingDroppedFrameCount.addingReportingOverflow(frameCount)
        if overflow {
            pendingDroppedFrameCount = Int.max
            timelineIsComplete.store(false, ordering: .relaxed)
        } else {
            pendingDroppedFrameCount = total
        }
        needsBoundary = true
    }
}
