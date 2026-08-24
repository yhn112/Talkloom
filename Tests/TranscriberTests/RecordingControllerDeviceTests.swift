import AVFoundation
import XCTest

@testable import Transcriber

/// Drives the controller the way the menu bar does, against real devices.
///
/// Everything below it is covered elsewhere; what is only exercised here is the wiring —
/// that pressing record starts both paths, that stopping closes both files, and that the
/// session ends up describing itself on disk.
@MainActor
final class RecordingControllerDeviceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TRANSCRIBER_DEVICE_TESTS"] == "1",
            "set TRANSCRIBER_DEVICE_TESTS=1 to run the tests that use real audio devices"
        )
    }

    func testARecordingProducesTwoTracksAndAManifestDescribingThem() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ControllerDeviceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RecordingController(sessionRoot: root)

        await controller.start()
        let session = try XCTUnwrap(
            controller.currentSession,
            "recording did not start: \(controller.errorMessage ?? "no error reported")")
        XCTAssertTrue(controller.isRecording)

        let speech = Process()
        speech.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speech.arguments = ["-r", "180", "One two three four five six seven eight"]
        try? speech.run()
        try await Task.sleep(for: .seconds(3))
        speech.terminate()
        speech.waitUntilExit()

        await controller.stop()
        XCTAssertFalse(controller.isRecording)

        let microphone = try XCTUnwrap(controller.lastMicrophoneTrack)
        let system = try XCTUnwrap(controller.lastSystemTrack)
        XCTAssertFalse(system.isSilent, "the system track heard nothing")
        XCTAssertGreaterThan(microphone.frameCount, 0)
        XCTAssertEqual(microphone.droppedSampleCount, 0)
        XCTAssertEqual(system.droppedSampleCount, 0)

        // The two tracks are never one file, and both actually reached disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.microphoneTrackURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemTrackURL.path))
        XCTAssertEqual(
            try AVAudioFile(forReading: session.microphoneTrackURL).length,
            AVAudioFramePosition(microphone.frameCount))
        XCTAssertEqual(
            try AVAudioFile(forReading: session.systemTrackURL).length,
            AVAudioFramePosition(system.frameCount))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(
            contentsOf: session.directory.appending(path: RecordingManifest.fileName))
        let manifest = try decoder.decode(RecordingManifest.self, from: data)

        XCTAssertEqual(Set(manifest.tracks.map(\.file)), ["mic.wav", "system.wav"])
        // Both paths came up, so the microphone is echo-cancelled and carries the user
        // alone. Nothing downstream can work that out from the audio, and this is the only
        // recording of it.
        XCTAssertEqual(manifest.tracks.first { $0.file == "mic.wav" }?.content, .local)
        XCTAssertEqual(manifest.tracks.first { $0.file == "system.wav" }?.content, .remote)
        XCTAssertNil(manifest.warning, "neither path was degraded")
        // The system tap produces its first sample almost at once; voice processing takes
        // the best part of a second to come up. The gap is accepted, but it has to be
        // written down, because nothing in the audio records it.
        let offsets = manifest.tracks.compactMap(\.startOffset)
        XCTAssertEqual(offsets.min(), 0, "the earliest track defines the origin")
        let micOffset = try XCTUnwrap(
            manifest.tracks.first { $0.file == "mic.wav" }?.startOffset
        )
        print("  microphone starts \(String(format: "%.3f", micOffset)) s after the system tap")
        XCTAssertGreaterThan(micOffset, 0)
        XCTAssertLessThan(micOffset, 5)
    }
}
