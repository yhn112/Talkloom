import AVFoundation
import Foundation
import Testing
import TranscriberCore

@testable import Transcriber

@Suite("Track recorder")
final class TrackRecorderTests {
    private let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "TrackRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class FailingWriter: PCMWriting {
        enum Mode { case append, finish }

        let mode: Mode
        private(set) var frameCount = 0

        init(_ mode: Mode) { self.mode = mode }

        func append(_ samples: UnsafeBufferPointer<Int16>) throws {
            if case .append = mode { throw CocoaError(.fileWriteOutOfSpace) }
            frameCount += samples.count
        }

        func finish() throws {
            if case .finish = mode { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// A tone rather than noise: a peak measurement on a known amplitude is the check that
    /// distinguishes a real recording from a valid file full of silence.
    private func tone(
        frequency: Double,
        amplitude: Float,
        seconds: Double,
        sampleRate: Double
    ) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { index in
            amplitude * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    private func peakAmplitude(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: file.fileFormat.sampleRate,
                channels: 1,
                interleaved: false))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData)[0]
        return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
    }

    /// The path a real recording takes, minus the device: samples in at the source rate, a
    /// WAV out at that same rate with the tone still in it. Capture resamples nothing.
    @Test("the source format is written untouched")
    func writesTheSourceFormatUntouched() async throws {
        let url = directory.appending(path: "mic.wav")
        let sourceRate = 48_000.0
        let recorder = try TrackRecorder(
            label: "mic",
            url: url,
            sampleRate: sourceRate,
            content: .local
        )
        let samples = tone(frequency: 440, amplitude: 0.5, seconds: 1, sampleRate: sourceRate)

        await recorder.start()
        // In blocks, the way a callback delivers them, with the drain loop running between.
        for chunk in stride(from: 0, to: samples.count, by: 1024) {
            let block = Array(samples[chunk..<min(chunk + 1024, samples.count)])
            block.withUnsafeBufferPointer {
                _ = recorder.input.ring.write($0.baseAddress!, count: block.count)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        let summary = await recorder.finish().summary

        #expect(summary.droppedSampleCount == 0, "the consumer kept up")
        // Not "close to": nothing on this path is allowed to lose a frame.
        #expect(summary.frameCount == samples.count)
        #expect(abs(summary.duration - 1.0) < 0.0001)
        #expect(!summary.isSilent)
        #expect(abs(summary.peakAmplitude - 0.5) < 0.0001)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == sourceRate)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == AVAudioFramePosition(samples.count))
        #expect(abs(try peakAmplitude(of: url) - 0.5) < 0.001)
    }

    @Test("a silent source is reported as silent")
    func aSilentSourceIsReportedAsSilent() async throws {
        let url = directory.appending(path: "silence.wav")
        let recorder = try TrackRecorder(
            label: "system", url: url, sampleRate: 48_000, content: .remote)

        await recorder.start()
        let silence = [Float](repeating: 0, count: 48_000)
        silence.withUnsafeBufferPointer {
            _ = recorder.input.ring.write($0.baseAddress!, count: silence.count)
        }
        let summary = await recorder.finish().summary

        #expect(summary.isSilent)
        #expect(summary.peakAmplitude == 0)
        #expect(summary.frameCount == 48_000, "silence still has to produce a file")
    }

    /// A full-scale sample must not wrap round to the most negative Int16, which is a click
    /// exactly where the recording was loudest.
    @Test("full-scale samples do not wrap")
    func fullScaleSamplesDoNotWrap() async throws {
        let url = directory.appending(path: "clipping.wav")
        let recorder = try TrackRecorder(
            label: "mic", url: url, sampleRate: 16_000, content: .local)
        let samples: [Float] = [1.0, -1.0, 2.0, -2.0, 0.999_99]

        await recorder.start()
        samples.withUnsafeBufferPointer {
            _ = recorder.input.ring.write($0.baseAddress!, count: samples.count)
        }
        let summary = await recorder.finish().summary

        #expect(summary.frameCount == samples.count)
        let data = try Data(contentsOf: url).subdata(in: 44..<(44 + samples.count * 2))
        let written = data.withUnsafeBytes { raw in
            (0..<samples.count).map {
                Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))
            }
        }
        #expect(written == [32_767, -32_767, 32_767, -32_767, 32_767])
    }

    @Test("an unusable sample rate is rejected")
    func anUnusableSampleRateIsRejected() {
        #expect(throws: TrackRecorder.Failure.self) {
            _ = try TrackRecorder(
                label: "mic",
                url: directory.appending(path: "bad.wav"),
                sampleRate: 0,
                content: .local
            )
        }
    }

    @Test("an append failure comes back with the partial summary")
    func appendFailureIsReturnedWithThePartialSummary() async throws {
        let recorder = try TrackRecorder(
            label: "mic",
            url: directory.appending(path: "failed.wav"),
            sampleRate: 48_000,
            content: .local,
            writer: FailingWriter(.append)
        )
        [Float](repeating: 0.5, count: 1_000).withUnsafeBufferPointer {
            _ = recorder.input.ring.write($0.baseAddress!, count: $0.count)
        }

        let completion = await recorder.finish()

        #expect(completion.summary.frameCount == 0)
        #expect(completion.summary.peakAmplitude == 0)
        #expect(completion.failure != nil)
        #expect(
            completion.failure?.localizedDescription.contains("could not write audio") == true)
    }

    @Test("a finalization failure comes back with the written summary")
    func finalizationFailureIsReturnedWithTheWrittenSummary() async throws {
        let recorder = try TrackRecorder(
            label: "system",
            url: directory.appending(path: "failed.wav"),
            sampleRate: 48_000,
            content: .remote,
            writer: FailingWriter(.finish)
        )
        [Float](repeating: 0.5, count: 1_000).withUnsafeBufferPointer {
            _ = recorder.input.ring.write($0.baseAddress!, count: $0.count)
        }

        let completion = await recorder.finish()

        #expect(completion.summary.frameCount == 1_000)
        #expect(completion.failure != nil)
        #expect(completion.failure?.localizedDescription.contains("WAV header") == true)
    }

    /// The first failure the drain sees, delivered the way a capture path receives it.
    private func firstReportedFailure(from recorder: TrackRecorder) async -> TrackRecorder.Failure {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<TrackRecorder.Failure, Never>) in
            Task {
                await recorder.observeFailures { continuation.resume(returning: $0) }
                await recorder.start()
            }
        }
    }

    /// A write failure belongs to the session while it is still running, not to `finish()`.
    /// Waiting for stop means the file quietly stopped growing behind a UI that still says
    /// "recording", and the rest of the meeting is gone before anyone is told.
    @Test("a write failure is reported without waiting for the session to stop")
    func aWriteFailureIsReportedWhileRecording() async throws {
        let recorder = try TrackRecorder(
            label: "mic",
            url: directory.appending(path: "reported.wav"),
            sampleRate: 48_000,
            content: .local,
            writer: FailingWriter(.append)
        )
        [Float](repeating: 0.5, count: 1_000).withUnsafeBufferPointer {
            _ = recorder.input.ring.write($0.baseAddress!, count: $0.count)
        }

        let failure = await firstReportedFailure(from: recorder)

        #expect(failure.localizedDescription.contains("could not write audio"))
        _ = await recorder.finish()
    }

    /// A drop is not a rounding error in the length. Whatever arrives afterwards is written
    /// directly behind what came before, so this track shortens and shifts against the
    /// other one, and `session.json` cannot yet say where the gap was. The track fails
    /// instead, and nothing from the pass that noticed reaches disk.
    @Test("dropped samples fail the track instead of compressing its timeline")
    func droppedSamplesFailTheTrack() async throws {
        // 8 kHz gives four seconds of ring in 32 768 samples, so one oversized block
        // overflows it without having to stall the consumer.
        let recorder = try TrackRecorder(
            label: "system",
            url: directory.appending(path: "dropped.wav"),
            sampleRate: 8_000,
            content: .remote
        )
        [Float](repeating: 0.5, count: 1_000).withUnsafeBufferPointer {
            _ = recorder.input.ring.write($0.baseAddress!, count: $0.count)
        }
        let overflowed = [Float](repeating: 0.5, count: 40_000).withUnsafeBufferPointer {
            recorder.input.ring.write($0.baseAddress!, count: $0.count)
        }
        #expect(!overflowed)

        let failure = await firstReportedFailure(from: recorder)
        let completion = await recorder.finish()

        #expect(failure == .samplesDropped(label: "system", sampleCount: 40_000))
        #expect(completion.failure == .samplesDropped(label: "system", sampleCount: 40_000))
        #expect(completion.summary.droppedSampleCount == 40_000)
        #expect(completion.summary.frameCount == 0)
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

    struct StereoLayout: Sendable, CustomTestStringConvertible {
        let name: String
        let interleaved: Bool
        let left: Float
        let right: Float
        let mean: Float

        var testDescription: String { name }
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
}
