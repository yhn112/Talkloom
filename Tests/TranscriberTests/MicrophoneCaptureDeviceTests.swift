import AVFoundation
import XCTest

@testable import Transcriber

/// Records from the real microphone. Compiling proves nothing about capture code — the
/// failure mode is a valid file of the right duration containing silence — so these are the
/// tests that decide whether the microphone path works.
///
/// They are opt-in because they need a microphone, working speakers, and the microphone
/// permission, and because they make audible noise:
///
///     TRANSCRIBER_DEVICE_TESTS=1 xcodebuild -project Transcriber.xcodeproj \
///       -scheme Transcriber -derivedDataPath build test \
///       -only-testing:TranscriberTests/MicrophoneCaptureDeviceTests
final class MicrophoneCaptureDeviceTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/dev/null")

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TRANSCRIBER_DEVICE_TESTS"] == "1",
            "set TRANSCRIBER_DEVICE_TESTS=1 to run the tests that use the real microphone"
        )
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MicrophoneDeviceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Speaks through the default output device so the microphone has something to hear.
    private func speakThroughTheSpeakers() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", "180", "One two three four five six seven eight nine ten"]
        try? process.run()
        return process
    }

    private func record(voiceProcessing: Bool, to name: String) async throws -> TrackRecorder.Summary {
        let capture = MicrophoneCapture()
        let url = directory.appending(path: name)

        _ = try await capture.start(writingTo: url, voiceProcessing: voiceProcessing)
        let speech = speakThroughTheSpeakers()
        try await Task.sleep(for: .seconds(4))
        speech.terminate()
        let summary = await capture.stop()
        let result = try XCTUnwrap(summary)
        // Printed because these numbers are the verification: a commit touching capture has
        // to carry the measured peak per track, not the assertion that it compiled.
        print(
            "  [\(name)] voiceProcessing=\(voiceProcessing) rate=\(result.sampleRate) Hz "
                + "frames=\(result.frameCount) duration=\(String(format: "%.2f", result.duration)) s "
                + "peak=\(String(format: "%.4f", result.peakAmplitude)) dropped=\(result.droppedSampleCount)"
        )
        return result
    }

    /// The whole chain against real hardware, with echo cancellation out of the way so the
    /// speakers reach the microphone: device → tap → ring buffer → resample-free WAV.
    func testTheMicrophoneRecordsAudibleAudio() async throws {
        let summary = try await record(voiceProcessing: false, to: "raw.wav")

        XCTAssertEqual(summary.duration, 4.0, accuracy: 0.5)
        XCTAssertEqual(summary.droppedSampleCount, 0, "the drain loop kept up with the device")
        XCTAssertFalse(summary.isSilent, "peak was \(summary.peakAmplitude) — the file is silent")
        XCTAssertGreaterThan(summary.peakAmplitude, 0.01, "the microphone heard the speakers")
        // Not an assertion about the code — a warning about this machine's input gain, which
        // would distort a real meeting the same way.
        if summary.isClipped {
            print("  warning: the microphone clipped at \(summary.peakAmplitude); the input volume is too high")
        }

        // The file on disk must agree with what the recorder reported.
        let file = try AVAudioFile(forReading: summary.url)
        XCTAssertEqual(file.fileFormat.sampleRate, summary.sampleRate)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, AVAudioFramePosition(summary.frameCount))
    }

    /// Echo cancellation has to actually cancel. A canceller that silently does nothing
    /// looks identical from the API's side, and only shows up later as every remote line
    /// appearing twice in the transcript.
    func testVoiceProcessingSuppressesTheSpeakers() async throws {
        let withoutCancellation = try await record(voiceProcessing: false, to: "raw.wav")
        let withCancellation = try await record(voiceProcessing: true, to: "aec.wav")

        XCTAssertFalse(withoutCancellation.isSilent, "the reference recording heard nothing")
        XCTAssertLessThan(
            withCancellation.peakAmplitude,
            withoutCancellation.peakAmplitude,
            "echo cancellation made no difference: \(withCancellation.peakAmplitude) vs \(withoutCancellation.peakAmplitude)"
        )
    }
}
