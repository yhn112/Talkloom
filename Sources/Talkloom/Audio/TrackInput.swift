import AVFoundation
import CoreAudio
import Synchronization
import TalkloomCore

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
    private let sampleRate: Double
    private let hostTicksPerSecond: Double
    private let precedingSegmentEndHostTime: UInt64?

    /// Producer-only state. The callback is the single writer required by the SPSC rings,
    /// so these values need no synchronization and must never be touched by the consumer.
    private var needsBoundary = true
    private var pendingDroppedFrameCount = 0
    private var derivesInitialSilenceFromAnchor: Bool
    private let acceptsWrites = Atomic<Bool>(true)
    private let activeWriteCount = Atomic<Int>(0)
    private let terminalDropCount = Atomic<Int>(0)

    /// The recorder reads these from its actor while the callback may still be running.
    private let didObserveTimeline = Atomic<Bool>(false)
    private let didAcceptSamples = Atomic<Bool>(false)
    private let timelineIsComplete = Atomic<Bool>(true)

    /// Mach host time represented by frame zero of the master, or 0 if none has arrived.
    ///
    /// This is the track's time origin, and it is recorded rather than assumed. Both
    /// capture paths hand over a mach timestamp taken by the audio hardware, and mach time
    /// is one clock for the whole machine — so the microphone and the system tap can be
    /// lined up against each other exactly, however far apart they happened to start.
    private let firstHostTime = Atomic<UInt64>(0)

    /// End of the last callback block on the machine clock. The capture owner reads this
    /// only after stopping this producer, then gives it to the next physical segment.
    private let lastEndHostTime = Atomic<UInt64>(0)

    /// Shape of the most recent block — buffer count, channels in the first buffer, and its
    /// size — kept for diagnosing a track whose length does not match the wall clock.
    private let lastListShape = Atomic<UInt64>(0)

    /// Blocks refused because the buffer list was not the single buffer expected.
    private let unexpectedLayouts = Atomic<Int>(0)

    /// - Parameters:
    ///   - ringCapacity: samples of headroom for the consumer, at the *source* sample rate.
    ///   - maximumFrameCount: largest block a callback may hand over. A larger block is
    ///     dropped rather than truncated, so size it generously.
    init(
        ringCapacity: Int,
        sampleRate: Double = 48_000,
        precedingSegmentEndHostTime: UInt64? = nil,
        maximumFrameCount: Int = 16_384
    ) {
        precondition(sampleRate > 0 && sampleRate.isFinite)
        ring = AudioRingBuffer(capacity: ringCapacity)
        // One boundary needs at least one accepted sample before another can follow. Giving
        // the sparse side ring the sample ring's capacity therefore makes metadata capacity
        // at least as large as the number of unresolved boundaries it can accompany.
        boundaries = TimelineBoundaryRing(capacity: ring.capacity)
        self.sampleRate = sampleRate
        self.hostTicksPerSecond = Double(HostTime.hostTicks(forSeconds: 1))
        self.precedingSegmentEndHostTime = precedingSegmentEndHostTime
        self.derivesInitialSilenceFromAnchor = precedingSegmentEndHostTime != nil
        scratchCapacity = maximumFrameCount
        scratch = .allocate(capacity: maximumFrameCount)
        scratch.initialize(repeating: 0, count: maximumFrameCount)
        if let precedingSegmentEndHostTime {
            firstHostTime.store(precedingSegmentEndHostTime, ordering: .relaxed)
            lastEndHostTime.store(precedingSegmentEndHostTime, ordering: .relaxed)
        }
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
        guard hasCompleteTimeline, didAcceptSamples.load(ordering: .relaxed) else { return nil }
        let value = firstHostTime.load(ordering: .relaxed)
        return value == 0 ? nil : value
    }

    /// Complete end anchor for handing this logical track to a replacement producer.
    /// The producer must already be stopped before this value is consumed.
    var lastSampleEndHostTime: UInt64? {
        guard timelineIsComplete.load(ordering: .acquiring) else { return nil }
        let value = lastEndHostTime.load(ordering: .acquiring)
        return value == 0 ? nil : value
    }

    /// Whether every written or replaced block had a hardware anchor and the drop counter
    /// remained representable. Direct access to `ring` is deliberately treated as unknown.
    var hasCompleteTimeline: Bool {
        didObserveTimeline.load(ordering: .relaxed)
            && timelineIsComplete.load(ordering: .relaxed)
            && (precedingSegmentEndHostTime == nil
                || didAcceptSamples.load(ordering: .relaxed))
    }

    /// Consumer-side boundary read. The recorder first acquires the audio write cursor, then
    /// calls this, matching the producer's boundary-before-audio publication order.
    func readBoundary() -> TimelineBoundary? { boundaries.read() }

    /// Any final rejected blocks after the last accepted span. The producer must already be
    /// stopped before the recorder asks for this value.
    func terminalDroppedFrameCount() -> Int {
        terminalDropCount.load(ordering: .acquiring)
    }

    /// Closes the callback handoff before finalization. A callback that already entered is
    /// counted until its bounded copy completes; later callbacks are refused.
    func closeProducer() {
        // These gate operations are sequentially consistent across both atomics. If a
        // callback increments after this store, its second gate read must refuse the write;
        // if it increments before this store, the consumer must observe the active count.
        acceptsWrites.store(false, ordering: .sequentiallyConsistent)
    }

    var hasActiveProducerWrite: Bool {
        activeWriteCount.load(ordering: .sequentiallyConsistent) != 0
    }

    /// Samples the producer had to throw away, either because the consumer fell behind or
    /// because a block was larger than the scratch buffer.
    var droppedSampleCount: Int { ring.droppedSampleCount }

    /// Accepts a block from an `AVAudioNodeTapBlock`.
    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer, atHostTime hostTime: UInt64? = nil) -> Bool {
        guard beginWrite() else { return false }
        defer { endWrite() }
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
        guard beginWrite() else { return false }
        defer { endWrite() }
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
        guard beginWrite() else { return false }
        defer { endWrite() }
        return writeMono(samples, frameCount: count, hostTime: hostTime)
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

        // A replacement segment cannot place samples until its first hardware anchor says
        // how much wall-clock time passed since the preceding physical segment. Refuse an
        // unanchored opening block; a later valid anchor accounts for the whole interval.
        if derivesInitialSilenceFromAnchor, validHostTime == nil {
            ring.recordDrop(sampleCount: frameCount)
            return false
        }
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
            let leadingSilence: Int
            if derivesInitialSilenceFromAnchor,
                let precedingSegmentEndHostTime,
                let validHostTime,
                let frames = nativeFrameCount(
                    from: precedingSegmentEndHostTime,
                    to: validHostTime
                )
            {
                leadingSilence = frames
            } else if derivesInitialSilenceFromAnchor {
                ring.recordDrop(sampleCount: frameCount)
                timelineIsComplete.store(false, ordering: .relaxed)
                return false
            } else {
                leadingSilence = pendingDroppedFrameCount
            }
            boundaries.write(
                TimelineBoundary(
                    sourceFrameOffset: ring.totalSampleCount,
                    startHostTime: validHostTime ?? 0,
                    silentFrameCount: leadingSilence
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
        terminalDropCount.store(0, ordering: .releasing)
        derivesInitialSilenceFromAnchor = false
        didAcceptSamples.store(true, ordering: .relaxed)
        noteEndpoint(hostTime: validHostTime, frameCount: frameCount)
        return true
    }

    private func recordDrop(frameCount: Int, hostTime: UInt64?) {
        didObserveTimeline.store(true, ordering: .relaxed)
        let validHostTime = hostTime.flatMap { $0 == 0 ? nil : $0 }
        if validHostTime == nil { timelineIsComplete.store(false, ordering: .relaxed) }
        if let validHostTime, timelineIsComplete.load(ordering: .relaxed) {
            _ = firstHostTime.compareExchange(
                expected: 0, desired: validHostTime, ordering: .relaxed)
        }
        ring.recordDrop(sampleCount: frameCount)
        if derivesInitialSilenceFromAnchor {
            needsBoundary = true
            return
        }
        noteEndpoint(hostTime: validHostTime, frameCount: frameCount)
        let (total, overflow) = pendingDroppedFrameCount.addingReportingOverflow(frameCount)
        if overflow {
            pendingDroppedFrameCount = Int.max
            timelineIsComplete.store(false, ordering: .relaxed)
        } else {
            pendingDroppedFrameCount = total
        }
        terminalDropCount.store(pendingDroppedFrameCount, ordering: .releasing)
        needsBoundary = true
    }

    /// Converts one local host-time interval to this segment's native frames. All floating
    /// point setup happened in `init`; the callback does only bounded arithmetic and stores.
    private func nativeFrameCount(from start: UInt64, to end: UInt64) -> Int? {
        guard end >= start else { return nil }
        let frames = (Double(end - start) * sampleRate / hostTicksPerSecond).rounded()
        guard frames.isFinite, let frameCount = Int(exactly: frames), frameCount >= 0 else {
            return nil
        }
        return frameCount
    }

    private func noteEndpoint(hostTime: UInt64?, frameCount: Int) {
        guard let hostTime else { return }
        let duration = (Double(frameCount) * hostTicksPerSecond / sampleRate).rounded()
        guard duration.isFinite, let durationTicks = UInt64(exactly: duration) else {
            timelineIsComplete.store(false, ordering: .relaxed)
            return
        }
        let (end, overflow) = hostTime.addingReportingOverflow(durationTicks)
        guard !overflow else {
            timelineIsComplete.store(false, ordering: .relaxed)
            return
        }
        let previous = lastEndHostTime.load(ordering: .relaxed)
        guard previous == 0 || end >= previous else {
            timelineIsComplete.store(false, ordering: .relaxed)
            return
        }
        lastEndHostTime.store(end, ordering: .releasing)
    }

    private func beginWrite() -> Bool {
        guard acceptsWrites.load(ordering: .sequentiallyConsistent) else { return false }
        _ = activeWriteCount.wrappingAdd(1, ordering: .sequentiallyConsistent)
        guard acceptsWrites.load(ordering: .sequentiallyConsistent) else {
            _ = activeWriteCount.wrappingSubtract(1, ordering: .sequentiallyConsistent)
            return false
        }
        return true
    }

    private func endWrite() {
        _ = activeWriteCount.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    }
}
