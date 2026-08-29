import AVFoundation
import Foundation
import TalkloomCore
import Testing

@testable import Talkloom

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
            source: .microphone,
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
            label: "system", url: url, source: .systemAudio, sampleRate: 48_000,
            content: .remote)

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
            label: "mic", url: url, source: .microphone, sampleRate: 16_000, content: .local)
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
                source: .microphone,
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
            source: .microphone,
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
            source: .systemAudio,
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

    @Test("the first timestamp is reported outside the audio callback")
    func firstTimestampIsReportedOutsideTheAudioCallback() async throws {
        let recorder = try TrackRecorder(
            label: "system",
            url: directory.appending(path: "timestamp.wav"),
            source: .systemAudio,
            sampleRate: 48_000,
            content: .remote
        )
        [Float](repeating: 0.25, count: 4).withUnsafeBufferPointer {
            #expect(
                recorder.input.write(
                    $0.baseAddress!, count: $0.count, atHostTime: 1_234
                ))
        }

        let reported = await withCheckedContinuation {
            (continuation: CheckedContinuation<UInt64, Never>) in
            Task {
                await recorder.observeFirstSample { continuation.resume(returning: $0) }
            }
        }

        #expect(reported == 1_234)
        _ = await recorder.finish()
    }

    @Test("only a signal after the observation begins satisfies the probe")
    func onlyANewSignalSatisfiesTheProbe() async throws {
        let recorder = try TrackRecorder(
            label: "system",
            url: directory.appending(path: "signal.wav"),
            source: .systemAudio,
            sampleRate: 48_000,
            content: .remote
        )
        await recorder.start()
        [Float](repeating: 0.02, count: 1_000).withUnsafeBufferPointer {
            _ = recorder.input.ring.write($0.baseAddress!, count: $0.count)
        }

        let staleObservation = await recorder.beginSignalObservation(above: 0.005)
        #expect(
            await !recorder.waitForSignal(staleObservation, timeout: .milliseconds(20)),
            "a peak from before the observation epoch cannot verify the probe")

        let activeObservation = await recorder.beginSignalObservation(above: 0.005)
        [Float](repeating: 0.02, count: 1_000).withUnsafeBufferPointer {
            _ = recorder.input.ring.write($0.baseAddress!, count: $0.count)
        }
        #expect(
            await recorder.waitForSignal(activeObservation, timeout: .milliseconds(200)))
        _ = await recorder.finish()
    }

    /// A write failure belongs to the session while it is still running, not to `finish()`.
    /// Waiting for stop means the file quietly stopped growing behind a UI that still says
    /// "recording", and the rest of the meeting is gone before anyone is told.
    @Test("a write failure is reported without waiting for the session to stop")
    func aWriteFailureIsReportedWhileRecording() async throws {
        let recorder = try TrackRecorder(
            label: "mic",
            url: directory.appending(path: "reported.wav"),
            source: .microphone,
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

    /// A refused block is materialized as native-rate silence between two anchored spans.
    /// The real samples after it remain in the file instead of stopping the whole meeting or
    /// being appended directly behind the earlier span and compressing the timeline.
    @Test("dropped samples become an explicit silent gap and recording continues")
    func droppedSamplesBecomeAnExplicitSilentGap() async throws {
        // 8 kHz gives four seconds of ring in 32 768 samples, so one oversized block
        // overflows it without having to stall the consumer.
        let url = directory.appending(path: "dropped.wav")
        let recorder = try TrackRecorder(
            label: "system",
            url: url,
            source: .systemAudio,
            sampleRate: 8_000,
            content: .remote
        )
        let origin: UInt64 = 1_000_000
        [Float](repeating: 0.5, count: 1_000).withUnsafeBufferPointer {
            #expect(
                recorder.input.write(
                    $0.baseAddress!, count: $0.count, atHostTime: origin
                ))
        }
        let overflowed = [Float](repeating: 0.5, count: 40_000).withUnsafeBufferPointer {
            recorder.input.write(
                $0.baseAddress!,
                count: $0.count,
                atHostTime: origin + HostTime.hostTicks(forSeconds: 0.125)
            )
        }
        #expect(!overflowed)

        await recorder.start()
        try await Task.sleep(for: .milliseconds(100))
        [Float](repeating: -0.5, count: 1_000).withUnsafeBufferPointer {
            #expect(
                recorder.input.write(
                    $0.baseAddress!,
                    count: $0.count,
                    atHostTime: origin + HostTime.hostTicks(forSeconds: 5.125)
                ))
        }
        let completion = await recorder.finish()

        #expect(completion.failure == nil)
        #expect(completion.summary.droppedSampleCount == 40_000)
        #expect(completion.summary.frameCount == 42_000)
        #expect(completion.summary.firstSampleHostTime == origin)
        #expect(
            completion.summary.spans == [
                .init(fileFrameOffset: 0, frameCount: 1_000, startHostTime: origin),
                .init(
                    fileFrameOffset: 41_000,
                    frameCount: 1_000,
                    startHostTime: origin + HostTime.hostTicks(forSeconds: 5.125)
                ),
            ])

        let data = try Data(contentsOf: url)
        let written = data.dropFirst(44).withUnsafeBytes { raw in
            (0..<42_000).map {
                Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))
            }
        }
        #expect(written[0] > 0)
        #expect(written[999] > 0)
        #expect(written[1_000..<41_000].allSatisfy { $0 == 0 })
        #expect(written[41_000] < 0)
        #expect(written[41_999] < 0)
    }

    @Test("multiple gaps queued before one drain preserve every boundary")
    func multipleGapsQueuedBeforeOneDrainPreserveEveryBoundary() async throws {
        let recorder = try TrackRecorder(
            label: "system",
            url: directory.appending(path: "multiple-gaps.wav"),
            source: .systemAudio,
            sampleRate: 100,
            content: .remote
        )
        let origin: UInt64 = 1_000_000
        let accepted = [Float](repeating: 0.5, count: 10)
        let dropped = [Float](repeating: 0.5, count: 600)

        accepted.withUnsafeBufferPointer {
            #expect(
                recorder.input.write(
                    $0.baseAddress!, count: $0.count, atHostTime: origin
                ))
        }
        dropped.withUnsafeBufferPointer {
            #expect(
                !recorder.input.write(
                    $0.baseAddress!,
                    count: $0.count,
                    atHostTime: origin + HostTime.hostTicks(forSeconds: 0.1)
                ))
        }
        accepted.withUnsafeBufferPointer {
            #expect(
                recorder.input.write(
                    $0.baseAddress!,
                    count: $0.count,
                    atHostTime: origin + HostTime.hostTicks(forSeconds: 6.1)
                ))
        }
        dropped.withUnsafeBufferPointer {
            #expect(
                !recorder.input.write(
                    $0.baseAddress!,
                    count: $0.count,
                    atHostTime: origin + HostTime.hostTicks(forSeconds: 6.2)
                ))
        }
        accepted.withUnsafeBufferPointer {
            #expect(
                recorder.input.write(
                    $0.baseAddress!,
                    count: $0.count,
                    atHostTime: origin + HostTime.hostTicks(forSeconds: 12.2)
                ))
        }

        let completion = await recorder.finish()

        #expect(completion.failure == nil)
        #expect(completion.summary.frameCount == 1_230)
        #expect(completion.summary.droppedSampleCount == 1_200)
        #expect(completion.summary.spans?.map(\.fileFrameOffset) == [0, 610, 1_220])
        #expect(completion.summary.spans?.map(\.frameCount) == [10, 10, 10])
    }

    @Test("an initial dropped block becomes silence before the first real span")
    func anInitialDroppedBlockBecomesSilenceBeforeTheFirstRealSpan() async throws {
        let recorder = try TrackRecorder(
            label: "system",
            url: directory.appending(path: "initial-gap.wav"),
            source: .systemAudio,
            sampleRate: 100,
            content: .remote
        )
        let origin: UInt64 = 1_000_000
        [Float](repeating: 0.5, count: 600).withUnsafeBufferPointer {
            #expect(
                !recorder.input.write(
                    $0.baseAddress!, count: $0.count, atHostTime: origin
                ))
        }
        [Float](repeating: 0.5, count: 10).withUnsafeBufferPointer {
            #expect(
                recorder.input.write(
                    $0.baseAddress!,
                    count: $0.count,
                    atHostTime: origin + HostTime.hostTicks(forSeconds: 6)
                ))
        }

        let completion = await recorder.finish()

        #expect(completion.failure == nil)
        #expect(completion.summary.firstSampleHostTime == origin)
        #expect(completion.summary.frameCount == 610)
        #expect(
            completion.summary.spans == [
                .init(
                    fileFrameOffset: 600,
                    frameCount: 10,
                    startHostTime: origin + HostTime.hostTicks(forSeconds: 6)
                )
            ])
    }

    @Test("a replacement segment writes the restart gap before post-gap signal")
    func replacementSegmentWritesLeadingRestartSilence() async throws {
        let url = directory.appending(path: "restart-gap.wav")
        let sampleRate = 100.0
        let precedingEnd = HostTime.hostTicks(forSeconds: 10)
        let resumedAt = precedingEnd + HostTime.hostTicks(forSeconds: 0.25)
        let recorder = try TrackRecorder(
            label: "system",
            url: url,
            source: .systemAudio,
            segmentIndex: 1,
            sampleRate: sampleRate,
            content: .remote,
            precedingSegmentEndHostTime: precedingEnd
        )
        let signal = [Float](repeating: -0.5, count: 10)

        signal.withUnsafeBufferPointer {
            #expect(
                recorder.input.write(
                    $0.baseAddress!, count: $0.count, atHostTime: resumedAt
                ))
        }
        let completion = await recorder.finish()

        #expect(completion.failure == nil)
        #expect(completion.summary.source == .systemAudio)
        #expect(completion.summary.segmentIndex == 1)
        #expect(completion.summary.firstSampleHostTime == precedingEnd)
        #expect(completion.summary.frameCount == 35)
        #expect(
            completion.summary.spans == [
                .init(fileFrameOffset: 25, frameCount: 10, startHostTime: resumedAt)
            ])

        let data = try Data(contentsOf: url)
        let written = data.dropFirst(44).withUnsafeBytes { raw in
            (0..<35).map {
                Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))
            }
        }
        #expect(written[..<25].allSatisfy { $0 == 0 })
        #expect(written[25...].allSatisfy { $0 < 0 })
    }

    @Test("a replacement drops an unanchored first block until an anchor arrives")
    func replacementWaitsForAValidFirstAnchor() async throws {
        let precedingEnd = HostTime.hostTicks(forSeconds: 20)
        let resumedAt = precedingEnd + HostTime.hostTicks(forSeconds: 0.25)
        let recorder = try TrackRecorder(
            label: "mic",
            url: directory.appending(path: "restart-anchor.wav"),
            source: .microphone,
            segmentIndex: 2,
            sampleRate: 100,
            content: .mixed,
            precedingSegmentEndHostTime: precedingEnd
        )
        let unanchored = [Float](repeating: 0.5, count: 10)
        let anchored = [Float](repeating: 0.25, count: 4)

        unanchored.withUnsafeBufferPointer {
            #expect(
                !recorder.input.write(
                    $0.baseAddress!, count: $0.count, atHostTime: nil
                ))
        }
        #expect(recorder.input.firstSampleHostTime == nil)
        #expect(!recorder.input.hasCompleteTimeline)
        anchored.withUnsafeBufferPointer {
            #expect(
                recorder.input.write(
                    $0.baseAddress!, count: $0.count, atHostTime: resumedAt
                ))
        }

        let completion = await recorder.finish()

        #expect(completion.failure == nil)
        #expect(completion.summary.droppedSampleCount == 10)
        #expect(completion.summary.frameCount == 29)
        #expect(completion.summary.firstSampleHostTime == precedingEnd)
        #expect(
            completion.summary.spans == [
                .init(fileFrameOffset: 25, frameCount: 4, startHostTime: resumedAt)
            ])
    }

    @Test("restart gap arithmetic uses the replacement native rate")
    func restartGapUsesChangedNativeRate() async throws {
        let precedingEnd = HostTime.hostTicks(forSeconds: 30)
        let resumedAt = precedingEnd + HostTime.hostTicks(forSeconds: 0.25)
        let recorder = try TrackRecorder(
            label: "system",
            url: directory.appending(path: "changed-rate-gap.wav"),
            source: .systemAudio,
            segmentIndex: 3,
            sampleRate: 44_100,
            content: .remote,
            precedingSegmentEndHostTime: precedingEnd
        )
        let signal = [Float](repeating: 0.5, count: 4)

        signal.withUnsafeBufferPointer {
            #expect(
                recorder.input.write(
                    $0.baseAddress!, count: $0.count, atHostTime: resumedAt
                ))
        }
        let completion = await recorder.finish()

        #expect(completion.failure == nil)
        #expect(completion.summary.sampleRate == 44_100)
        #expect(completion.summary.frameCount == 11_029)
        #expect(completion.summary.spans?.first?.fileFrameOffset == 11_025)
        #expect(completion.summary.spans?.first?.frameCount == 4)
    }

}
