import AVFoundation
import Testing

@testable import Talkloom

@Suite("Track input")
struct TrackInputTests {
    struct StereoLayout: Sendable, CustomTestStringConvertible {
        let name: String
        let interleaved: Bool
        let left: Float
        let right: Float
        let mean: Float

        var testDescription: String { name }
    }

    /// The producer's downmix. Whatever the device hands over, one averaged channel comes
    /// out, and the amplitude survives — a halved track is the quiet-remote-party complaint.
    @Test(
        "a stereo block is averaged to mono",
        arguments: [
            StereoLayout(name: "interleaved", interleaved: true, left: 1.0, right: 0.5, mean: 0.75),
            StereoLayout(
                name: "deinterleaved", interleaved: false, left: 1.0, right: 0, mean: 0.5),
        ]
    )
    func stereoIsAveragedToMono(_ layout: StereoLayout) throws {
        let input = TrackInput(ringCapacity: 4096)
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2,
                interleaved: layout.interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<4 {
            if layout.interleaved {
                channels[0][frame * 2] = layout.left
                channels[0][frame * 2 + 1] = layout.right
            } else {
                channels[0][frame] = layout.left
                channels[1][frame] = layout.right
            }
        }

        #expect(input.write(buffer))

        var out = [Float](repeating: .nan, count: 4)
        let read = out.withUnsafeMutableBufferPointer {
            input.ring.read(into: $0.baseAddress!, count: 4)
        }
        #expect(read == 4)
        #expect(out == [Float](repeating: layout.mean, count: 4))
    }

    @Test("mono goes straight through untouched")
    func monoGoesStraightThroughUntouched() throws {
        let input = TrackInput(ringCapacity: 4096)
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<4 { channels[0][frame] = Float(frame) / 4 }

        #expect(input.write(buffer))

        var out = [Float](repeating: .nan, count: 4)
        _ = out.withUnsafeMutableBufferPointer { input.ring.read(into: $0.baseAddress!, count: 4) }
        #expect(out == [0, 0.25, 0.5, 0.75])
    }

    /// The shape a CoreAudio process tap delivers.
    @Test("an audio buffer list is accepted")
    func audioBufferListIsAccepted() throws {
        let input = TrackInput(ringCapacity: 4096)
        var samples: [Float] = [0.1, 0.2, 0.3, 0.4]

        samples.withUnsafeMutableBufferPointer { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(raw.count * MemoryLayout<Float>.size),
                    mData: raw.baseAddress
                )
            )
            #expect(input.write(&list))
        }

        var out = [Float](repeating: .nan, count: 4)
        let read = out.withUnsafeMutableBufferPointer {
            input.ring.read(into: $0.baseAddress!, count: 4)
        }
        #expect(read == 4)
        #expect(out == [0.1, 0.2, 0.3, 0.4])
    }

    @Test("an oversized block is dropped whole and counted")
    func anOversizedBlockIsDroppedWholeAndCounted() throws {
        let input = TrackInput(ringCapacity: 1 << 16, maximumFrameCount: 8)
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2,
                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16

        #expect(!input.write(buffer))
        #expect(input.droppedSampleCount == 16)
        #expect(input.ring.availableToRead == 0)
    }

    @Test("a full boundary ring refuses unmarked audio")
    func aFullBoundaryRingRefusesUnmarkedAudio() {
        let input = TrackInput(ringCapacity: 4)
        let accepted = [Float](repeating: 0.5, count: 1)
        let dropped = [Float](repeating: 0.5, count: 5)
        var sink: Float = 0

        for index in 0..<4 {
            accepted.withUnsafeBufferPointer {
                #expect(
                    input.write(
                        $0.baseAddress!,
                        count: $0.count,
                        atHostTime: UInt64(1_000 + index * 10)
                    ))
            }
            #expect(input.ring.read(into: &sink, count: 1) == 1)
            dropped.withUnsafeBufferPointer {
                #expect(
                    !input.write(
                        $0.baseAddress!,
                        count: $0.count,
                        atHostTime: UInt64(1_001 + index * 10)
                    ))
            }
        }

        accepted.withUnsafeBufferPointer {
            #expect(
                !input.write(
                    $0.baseAddress!, count: $0.count, atHostTime: 2_000
                ))
        }

        #expect(input.ring.availableToRead == 0)
        #expect(input.droppedSampleCount == 21)
    }
}
