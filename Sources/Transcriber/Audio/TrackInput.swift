import AVFoundation
import CoreAudio

/// The producer's end of one recorded track — everything an audio callback is allowed to
/// touch, and nothing else.
///
/// Real-time safe by construction: a scratch buffer allocated once in `init`, a downmix
/// that is a bounded loop over the block, and a lock-free ring buffer. No allocation, no
/// locks, no file I/O, no `await`.
///
/// The downmix happens here, on the real-time side, on purpose. The canonical format is
/// mono, and doing it here means `AVAudioConverter` downstream is only ever asked to
/// change the sample rate, never the channel count — which is the configuration that
/// silently emits silence when Voice Processing IO reports an unexpected channel layout.
///
/// `@unchecked Sendable`: the ring buffer carries its own justification, and `scratch` is
/// allocated in `init`, freed in `deinit`, and only ever touched by the single audio thread
/// that calls `write`.
final class TrackInput: @unchecked Sendable {
    let ring: AudioRingBuffer

    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int

    /// - Parameters:
    ///   - ringCapacity: samples of headroom for the consumer, at the *source* sample rate.
    ///   - maximumFrameCount: largest block a callback may hand over. A larger block is
    ///     dropped rather than truncated, so size it generously.
    init(ringCapacity: Int, maximumFrameCount: Int = 16_384) {
        ring = AudioRingBuffer(capacity: ringCapacity)
        scratchCapacity = maximumFrameCount
        scratch = .allocate(capacity: maximumFrameCount)
        scratch.initialize(repeating: 0, count: maximumFrameCount)
    }

    deinit {
        scratch.deinitialize(count: scratchCapacity)
        scratch.deallocate()
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
    /// A list is either one buffer holding interleaved channels or one mono buffer per
    /// channel; both shapes occur, so both are handled rather than assumed.
    @discardableResult
    func write(_ bufferList: UnsafePointer<AudioBufferList>) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first, first.mDataByteSize > 0, let firstData = first.mData else {
            return true
        }

        if buffers.count == 1 {
            let channelCount = Int(first.mNumberChannels)
            guard channelCount > 0 else { return true }
            let frameCount = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            return write(
                interleaved: firstData.assumingMemoryBound(to: Float.self),
                frameCount: frameCount,
                channelCount: channelCount
            )
        }

        let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard frameCount > 0, frameCount <= scratchCapacity else {
            ring.recordDrop(sampleCount: max(frameCount, 1))
            return false
        }

        scratch.update(from: firstData.assumingMemoryBound(to: Float.self), count: frameCount)
        var mixedChannels = 1
        for buffer in buffers.dropFirst() {
            guard let data = buffer.mData, Int(buffer.mDataByteSize) >= frameCount * MemoryLayout<Float>.size else {
                continue
            }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                scratch[frame] += samples[frame]
            }
            mixedChannels += 1
        }
        if mixedChannels > 1 {
            let scale = 1 / Float(mixedChannels)
            for frame in 0..<frameCount {
                scratch[frame] *= scale
            }
        }
        return ring.write(scratch, count: frameCount)
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
