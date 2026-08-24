import AVFoundation
import XCTest

@testable import Transcriber

/// Records the machine's own output through a CoreAudio process tap. Opt-in for the same
/// reasons as the microphone tests, plus one of its own: the first run asks for the Audio
/// Recording permission, and until it is granted the tap produces a silent file rather than
/// an error.
///
///     xcodebuild -project Transcriber.xcodeproj -scheme TranscriberDeviceTests \
///       -derivedDataPath build test \
///       -only-testing:TranscriberTests/SystemAudioCaptureDeviceTests
final class SystemAudioCaptureDeviceTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/dev/null")

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TRANSCRIBER_DEVICE_TESTS"] == "1",
            "set TRANSCRIBER_DEVICE_TESTS=1 to run the tests that use real audio devices"
        )
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "SystemAudioDeviceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func playSomething() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", "180", "One two three four five six seven eight nine ten"]
        try? process.run()
        return process
    }

    private func report(_ summary: TrackRecorder.Summary, _ input: TrackInput? = nil) {
        if let input {
            let shape = input.lastBufferListShape
            print("  [\(summary.label)] last block: \(shape.buffers) buffer(s), \(shape.channels) ch, \(shape.byteCount) bytes")
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
    func testTheTapRecordsWhatTheMachinePlays() async throws {
        let capture = SystemAudioCapture()
        let url = directory.appending(path: "system.wav")

        let sampleRate = try await capture.start(writingTo: url)
        let playback = playSomething()
        try await Task.sleep(for: .seconds(4))
        playback.terminate()
        let stopped = await capture.stop()
        let summary = try XCTUnwrap(stopped).summary
        report(summary)

        XCTAssertGreaterThan(sampleRate, 0)
        XCTAssertEqual(summary.duration, 4.0, accuracy: 1.0)
        XCTAssertEqual(summary.droppedSampleCount, 0, "the drain loop kept up with the tap")
        XCTAssertFalse(
            summary.isSilent,
            "peak was \(summary.peakAmplitude); grant Audio Recording under System Settings › Privacy & Security"
        )
        XCTAssertGreaterThan(summary.peakAmplitude, 0.01)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, summary.sampleRate)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, AVAudioFramePosition(summary.frameCount))
    }

    /// Both tracks running at once, which is the only configuration that matters. They must
    /// each carry a timestamp from the audio hardware, because the two streams do not start
    /// together and everything downstream merges them on that offset.
    func testBothTracksRecordTogetherAndShareATimeOrigin() async throws {
        let microphone = MicrophoneCapture()
        let systemAudio = SystemAudioCapture()
        let microphoneURL = directory.appending(path: "mic.wav")
        let systemURL = directory.appending(path: "system.wav")

        _ = try await microphone.start(writingTo: microphoneURL)
        _ = try await systemAudio.start(writingTo: systemURL)
        let playback = playSomething()
        try await Task.sleep(for: .seconds(4))
        playback.terminate()

        let stoppedMicrophone = await microphone.stop()
        let stoppedSystem = await systemAudio.stop()
        let microphoneTrack = try XCTUnwrap(stoppedMicrophone).summary
        let systemTrack = try XCTUnwrap(stoppedSystem).summary
        report(microphoneTrack)
        report(systemTrack)

        XCTAssertNotEqual(microphoneTrack.url, systemTrack.url, "the tracks are never one file")
        XCTAssertFalse(systemTrack.isSilent, "the system track heard nothing")
        XCTAssertGreaterThan(microphoneTrack.frameCount, 0)

        let microphoneStart = try XCTUnwrap(microphoneTrack.firstSampleHostTime)
        let systemStart = try XCTUnwrap(systemTrack.firstSampleHostTime)
        let offset = HostTime.seconds(from: microphoneStart, to: systemStart)
        print("  system audio started \(String(format: "%.3f", offset)) s after the microphone")

        // Not an assertion that they start together — they do not, and the code must not
        // assume they do. Only that the offset is a plausible number rather than a mach
        // timebase conversion gone wrong by orders of magnitude.
        XCTAssertLessThan(abs(offset), 10.0)
    }
}
