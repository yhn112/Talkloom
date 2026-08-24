import AVFoundation
import XCTest

@testable import Transcriber

final class TrackRecorderTests: XCTestCase {
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

    private var directory = URL(fileURLWithPath: "/dev/null")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "TrackRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
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
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.fileFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
    }

    /// The path a real recording takes, minus the device: samples in at the source rate, a
    /// WAV out at that same rate with the tone still in it. Capture resamples nothing.
    func testWritesTheSourceFormatUntouched() async throws {
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
            block.withUnsafeBufferPointer { _ = recorder.input.ring.write($0.baseAddress!, count: block.count) }
            try await Task.sleep(for: .milliseconds(2))
        }
        let summary = await recorder.finish().summary

        XCTAssertEqual(summary.droppedSampleCount, 0, "the consumer kept up")
        // Not "close to": nothing on this path is allowed to lose a frame.
        XCTAssertEqual(summary.frameCount, samples.count)
        XCTAssertEqual(summary.duration, 1.0, accuracy: 0.0001)
        XCTAssertFalse(summary.isSilent)
        XCTAssertEqual(summary.peakAmplitude, 0.5, accuracy: 0.0001)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, sourceRate)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, AVAudioFramePosition(samples.count))
        XCTAssertEqual(try peakAmplitude(of: url), 0.5, accuracy: 0.001)
    }

    func testASilentSourceIsReportedAsSilent() async throws {
        let url = directory.appending(path: "silence.wav")
        let recorder = try TrackRecorder(label: "system", url: url, sampleRate: 48_000, content: .remote)

        await recorder.start()
        let silence = [Float](repeating: 0, count: 48_000)
        silence.withUnsafeBufferPointer { _ = recorder.input.ring.write($0.baseAddress!, count: silence.count) }
        let summary = await recorder.finish().summary

        XCTAssertTrue(summary.isSilent)
        XCTAssertEqual(summary.peakAmplitude, 0, accuracy: 0.0001)
        XCTAssertEqual(summary.frameCount, 48_000, "silence still has to produce a file")
    }

    /// A full-scale sample must not wrap round to the most negative Int16, which is a click
    /// exactly where the recording was loudest.
    func testFullScaleSamplesDoNotWrap() async throws {
        let url = directory.appending(path: "clipping.wav")
        let recorder = try TrackRecorder(label: "mic", url: url, sampleRate: 16_000, content: .local)
        let samples: [Float] = [1.0, -1.0, 2.0, -2.0, 0.999_99]

        await recorder.start()
        samples.withUnsafeBufferPointer { _ = recorder.input.ring.write($0.baseAddress!, count: samples.count) }
        let summary = await recorder.finish().summary

        XCTAssertEqual(summary.frameCount, samples.count)
        let data = try Data(contentsOf: url).subdata(in: 44..<(44 + samples.count * 2))
        let written = data.withUnsafeBytes { raw in
            (0..<samples.count).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
        XCTAssertEqual(written, [32_767, -32_767, 32_767, -32_767, 32_767])
    }

    func testAnUnusableSampleRateIsRejected() {
        let url = directory.appending(path: "bad.wav")
        XCTAssertThrowsError(try TrackRecorder(label: "mic", url: url, sampleRate: 0, content: .local))
    }

    func testAppendFailureIsReturnedWithThePartialSummary() async throws {
        let writer = FailingWriter(.append)
        let recorder = try TrackRecorder(
            label: "mic",
            url: directory.appending(path: "failed.wav"),
            sampleRate: 48_000,
            content: .local,
            writer: writer
        )
        [Float](repeating: 0.5, count: 1_000).withUnsafeBufferPointer {
            _ = recorder.input.ring.write($0.baseAddress!, count: $0.count)
        }

        let completion = await recorder.finish()

        XCTAssertEqual(completion.summary.frameCount, 0)
        XCTAssertEqual(completion.summary.peakAmplitude, 0)
        XCTAssertNotNil(completion.failure)
        XCTAssertTrue(completion.failure?.localizedDescription.contains("could not write audio") == true)
    }

    func testFinalizationFailureIsReturnedWithTheWrittenSummary() async throws {
        let writer = FailingWriter(.finish)
        let recorder = try TrackRecorder(
            label: "system",
            url: directory.appending(path: "failed.wav"),
            sampleRate: 48_000,
            content: .remote,
            writer: writer
        )
        [Float](repeating: 0.5, count: 1_000).withUnsafeBufferPointer {
            _ = recorder.input.ring.write($0.baseAddress!, count: $0.count)
        }

        let completion = await recorder.finish()

        XCTAssertEqual(completion.summary.frameCount, 1_000)
        XCTAssertNotNil(completion.failure)
        XCTAssertTrue(completion.failure?.localizedDescription.contains("WAV header") == true)
    }

    /// The producer's downmix. Two channels in, one averaged channel out — and the
    /// amplitude must survive, since a halved track is the quiet-remote-party complaint.
    func testInterleavedStereoIsAveragedToMono() throws {
        let input = TrackInput(ringCapacity: 4096)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        let interleaved = buffer.floatChannelData![0]
        for frame in 0..<4 {
            interleaved[frame * 2] = 1.0
            interleaved[frame * 2 + 1] = 0.5
        }

        XCTAssertTrue(input.write(buffer))

        var out = [Float](repeating: .nan, count: 4)
        let read = out.withUnsafeMutableBufferPointer { input.ring.read(into: $0.baseAddress!, count: 4) }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(out, [0.75, 0.75, 0.75, 0.75])
    }

    func testDeinterleavedStereoIsAveragedToMono() throws {
        let input = TrackInput(ringCapacity: 4096)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        for frame in 0..<4 {
            buffer.floatChannelData![0][frame] = 1.0
            buffer.floatChannelData![1][frame] = 0.0
        }

        XCTAssertTrue(input.write(buffer))

        var out = [Float](repeating: .nan, count: 4)
        let read = out.withUnsafeMutableBufferPointer { input.ring.read(into: $0.baseAddress!, count: 4) }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(out, [0.5, 0.5, 0.5, 0.5])
    }

    func testMonoGoesStraightThroughUntouched() throws {
        let input = TrackInput(ringCapacity: 4096)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        for frame in 0..<4 { buffer.floatChannelData![0][frame] = Float(frame) / 4 }

        XCTAssertTrue(input.write(buffer))

        var out = [Float](repeating: .nan, count: 4)
        _ = out.withUnsafeMutableBufferPointer { input.ring.read(into: $0.baseAddress!, count: 4) }
        XCTAssertEqual(out, [0, 0.25, 0.5, 0.75])
    }

    /// The shape a CoreAudio process tap delivers.
    func testAudioBufferListIsAccepted() throws {
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
            XCTAssertTrue(input.write(&list))
        }

        var out = [Float](repeating: .nan, count: 4)
        let read = out.withUnsafeMutableBufferPointer { input.ring.read(into: $0.baseAddress!, count: 4) }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(out, [0.1, 0.2, 0.3, 0.4])
    }

    func testAnOversizedBlockIsDroppedWholeAndCounted() throws {
        let input = TrackInput(ringCapacity: 1 << 16, maximumFrameCount: 8)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16

        XCTAssertFalse(input.write(buffer))
        XCTAssertEqual(input.droppedSampleCount, 16)
        XCTAssertEqual(input.ring.availableToRead, 0)
    }
}
