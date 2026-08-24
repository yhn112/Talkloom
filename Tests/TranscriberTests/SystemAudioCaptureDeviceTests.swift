import AVFoundation
import Foundation
import Testing
import TranscriberCore

@testable import Transcriber

extension DeviceTests {
    /// Records the machine's own output through a CoreAudio process tap. Opt-in for the
    /// same reasons as the microphone tests, plus one of its own: the first run asks for
    /// the Audio Recording permission, and until it is granted the tap produces a silent
    /// file rather than an error.
    @Suite("system audio capture")
    final class SystemAudio {
        private let directory: URL

        init() throws {
            directory = try DeviceTests.makeDirectory("SystemAudioDeviceTests")
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        private func report(_ summary: TrackRecorder.Summary, _ input: TrackInput? = nil) {
            if let input {
                let shape = input.lastBufferListShape
                print(
                    "  [\(summary.label)] last block: \(shape.buffers) buffer(s), \(shape.channels) ch, \(shape.byteCount) bytes"
                )
            }
            print(
                "  [\(summary.label)] rate=\(summary.sampleRate) Hz frames=\(summary.frameCount) "
                    + "duration=\(String(format: "%.2f", summary.duration)) s "
                    + "peak=\(String(format: "%.4f", summary.peakAmplitude)) dropped=\(summary.droppedSampleCount)"
            )
        }

        /// The tap has to hear what the machine plays. A silent file here means either the
        /// permission is missing or the aggregate device was built wrong — both look like
        /// success from the API's side.
        @Test("the tap records what the machine plays")
        func theTapRecordsWhatTheMachinePlays() async throws {
            let capture = SystemAudioCapture()
            let url = directory.appending(path: "system.wav")

            let sampleRate = try await capture.start(writingTo: url)
            let playback = DeviceTests.speak()
            try await Task.sleep(for: .seconds(4))
            playback.terminate()
            let summary = try #require(await capture.stop()).summary
            report(summary)

            #expect(sampleRate > 0)
            #expect(abs(summary.duration - 4.0) < 1.0)
            #expect(summary.droppedSampleCount == 0, "the drain loop kept up with the tap")
            #expect(
                !summary.isSilent,
                "peak was \(summary.peakAmplitude); grant Audio Recording under System Settings › Privacy & Security"
            )
            #expect(summary.peakAmplitude > 0.01)

            let file = try AVAudioFile(forReading: url)
            #expect(file.fileFormat.sampleRate == summary.sampleRate)
            #expect(file.fileFormat.channelCount == 1)
            #expect(file.length == AVAudioFramePosition(summary.frameCount))
        }

        /// Both tracks running at once, which is the only configuration that matters. They
        /// must each carry a timestamp from the audio hardware, because the two streams do
        /// not start together and everything downstream merges them on that offset.
        @Test("both tracks record together and share a time origin")
        func bothTracksRecordTogetherAndShareATimeOrigin() async throws {
            let microphone = MicrophoneCapture()
            let systemAudio = SystemAudioCapture()
            let microphoneURL = directory.appending(path: "mic.wav")
            let systemURL = directory.appending(path: "system.wav")

            _ = try await systemAudio.start(writingTo: systemURL)
            // Match production order: preserve remote audio while Voice Processing IO
            // starts. Bringing VPIO up mutates the output graph, so this order needs its own
            // hardware coverage even though the inverse order is easier on CoreAudio.
            _ = try await microphone.start(writingTo: microphoneURL)
            let playback = DeviceTests.speak()
            try await Task.sleep(for: .seconds(4))
            playback.terminate()

            let microphoneTrack = try #require(await microphone.stop()).summary
            let systemTrack = try #require(await systemAudio.stop()).summary
            report(microphoneTrack)
            report(systemTrack)

            #expect(microphoneTrack.url != systemTrack.url, "the tracks are never one file")
            #expect(!systemTrack.isSilent, "the system track heard nothing")
            #expect(microphoneTrack.frameCount > 0)

            let microphoneStart = try #require(microphoneTrack.firstSampleHostTime)
            let systemStart = try #require(systemTrack.firstSampleHostTime)
            let offset = HostTime.seconds(from: microphoneStart, to: systemStart)
            print("  system audio started \(String(format: "%.3f", offset)) s after the microphone")

            // Not an assertion that they start together — they do not, and the code must not
            // assume they do. Only that the offset is a plausible number rather than a mach
            // timebase conversion gone wrong by orders of magnitude.
            #expect(abs(offset) < 10.0)
        }
    }
}
