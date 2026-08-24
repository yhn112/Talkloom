import AVFoundation
import Atomics
import CoreAudio

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

    /// Mach host time of the first block this track received, or 0 if none has arrived.
    ///
    /// This is the track's time origin, and it is recorded rather than assumed. Both
    /// capture paths hand over a mach timestamp taken by the audio hardware, and mach time
    /// is one clock for the whole machine — so the microphone and the system tap can be
    /// lined up against each other exactly, however far apart they happened to start.
    private let firstHostTime: UnsafeAtomic<UInt64>

    /// Shape of the most recent block — buffer count, channels in the first buffer, and its
    /// size — kept for diagnosing a track whose length does not match the wall clock.
    private let lastListShape = UnsafeAtomic<UInt64>.create(0)

    /// Blocks refused because the buffer list was not the single buffer expected.
    private let unexpectedLayouts = UnsafeAtomic<Int>.create(0)

    /// - Parameters:
    ///   - ringCapacity: samples of headroom for the consumer, at the *source* sample rate.
    ///   - maximumFrameCount: largest block a callback may hand over. A larger block is
    ///     dropped rather than truncated, so size it generously.
    init(ringCapacity: Int, maximumFrameCount: Int = 16_384) {
        ring = AudioRingBuffer(capacity: ringCapacity)
        scratchCapacity = maximumFrameCount
        scratch = .allocate(capacity: maximumFrameCount)
        scratch.initialize(repeating: 0, count: maximumFrameCount)
        firstHostTime = .create(0)
    }

    deinit {
        scratch.deinitialize(count: scratchCapacity)
        scratch.deallocate()
        firstHostTime.destroy()
        lastListShape.destroy()
        unexpectedLayouts.destroy()
    }

    /// Records the timestamp of the first block, ignoring every one after it. Real-time
    /// safe: one uncontended compare-exchange that succeeds exactly once per recording.
    func noteFirstHostTime(_ hostTime: UInt64) {
        guard hostTime != 0 else { return }
        _ = firstHostTime.compareExchange(expected: 0, desired: hostTime, ordering: .relaxed)
    }

    /// How many blocks were refused for arriving in an unexpected buffer layout.
    var unexpectedLayoutCount: Int { unexpectedLayouts.load(ordering: .relaxed) }

    /// Buffer count, channel count and byte size of the last block received.
    var lastBufferListShape: (buffers: Int, channels: Int, byteCount: Int) {
        let shape = lastListShape.load(ordering: .relaxed)
        return (Int(shape >> 48), Int((shape >> 32) & 0xFFFF), Int(shape & 0xFFFF_FFFF))
    }

    /// When the first sample arrived, or `nil` if the track never received one.
    var firstSampleHostTime: UInt64? {
        let value = firstHostTime.load(ordering: .relaxed)
        return value == 0 ? nil : value
    }

    /// Samples the producer had to throw away, either because the consumer fell behind or
    /// because a block was larger than the scratch buffer.
    var droppedSampleCount: Int { ring.droppedSampleCount }

    /// Accepts a block from an `AVAudioNodeTapBlock`.
    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channels = buffer.floatChannelData else { return true }

        let channelCount = Int(buffer.format.channelCount)
        if buffer.format.isInterleaved {
            return write(interleaved: channels[0], frameCount: frameCount, channelCount: channelCount)
        }
        return write(deinterleaved: channels, frameCount: frameCount, channelCount: channelCount)
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
    func write(_ bufferList: UnsafePointer<AudioBufferList>) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first else { return true }

        lastListShape.store(
            UInt64(buffers.count) << 48 | UInt64(first.mNumberChannels) << 32 | UInt64(first.mDataByteSize),
            ordering: .relaxed
        )

        let channelCount = Int(first.mNumberChannels)
        guard buffers.count == 1, channelCount > 0, let data = first.mData else {
            unexpectedLayouts.wrappingIncrement(ordering: .relaxed)
            return false
        }
        guard first.mDataByteSize > 0 else { return true }

        return write(
            interleaved: data.assumingMemoryBound(to: Float.self),
            frameCount: Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channelCount),
            channelCount: channelCount
        )
    }

    private func write(
        interleaved samples: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> Bool {
        guard frameCount > 0 else { return true }
        guard channelCount > 1 else { return ring.write(samples, count: frameCount) }
        guard frameCount <= scratchCapacity else {
            ring.recordDrop(sampleCount: frameCount)
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
        return ring.write(scratch, count: frameCount)
    }

    private func write(
        deinterleaved channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        channelCount: Int
    ) -> Bool {
        guard channelCount > 1 else { return ring.write(channels[0], count: frameCount) }
        guard frameCount <= scratchCapacity else {
            ring.recordDrop(sampleCount: frameCount)
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
        return ring.write(scratch, count: frameCount)
    }
}
