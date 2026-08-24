import Foundation
import TranscriberCore
import XCTest

final class RecordingManifestTests: XCTestCase {
    private func report(
        _ label: String,
        hostTime: UInt64?,
        frameCount: Int = 48_000,
        content: TrackContent = .local
    ) -> TrackReport {
        TrackReport(
            file: "\(label).wav",
            content: content,
            sampleRate: 48_000,
            frameCount: frameCount,
            peakAmplitude: 0.5,
            droppedSampleCount: 0,
            firstSampleHostTime: hostTime
        )
    }

    /// The offset is the whole reason the manifest exists: the tracks do not start
    /// together, and nothing in the audio says by how much.
    func testOffsetsAreRelativeToWhicheverTrackStartedFirst() throws {
        let second = HostTime.hostTicks(forSeconds: 0.75)
        let manifest = RecordingManifest(
            startedAt: Date(timeIntervalSince1970: 0),
            reports: [
                report("mic", hostTime: 1_000 + second),
                report("system", hostTime: 1_000),
            ]
        )
        XCTAssertEqual(manifest.status, .completed)

        let mic = try XCTUnwrap(manifest.tracks.first { $0.file == "mic.wav" })
        let system = try XCTUnwrap(manifest.tracks.first { $0.file == "system.wav" })
        XCTAssertEqual(system.startOffset, 0, "the earliest track defines the origin")
        XCTAssertEqual(try XCTUnwrap(mic.startOffset), 0.75, accuracy: 0.001)
    }

    /// A track that never received a sample cannot be aligned, and must not drag the
    /// origin somewhere arbitrary.
    func testATrackThatNeverStartedGetsNoOffset() throws {
        let manifest = RecordingManifest(
            startedAt: Date(timeIntervalSince1970: 0),
            reports: [report("mic", hostTime: 5_000), report("system", hostTime: nil)]
        )
        XCTAssertEqual(manifest.status, .completed)

        let system = try XCTUnwrap(manifest.tracks.first { $0.file == "system.wav" })
        XCTAssertNil(system.startOffset)
        XCTAssertEqual(try XCTUnwrap(manifest.tracks.first { $0.file == "mic.wav" }).startOffset, 0)
    }

    func testItRoundTripsThroughTheFileItWrites() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "Manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = RecordingManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            reports: [report("mic", hostTime: 1_000), report("system", hostTime: 1_000)],
            failure: "capture stopped"
        )
        XCTAssertEqual(manifest.status, .failed)
        try manifest.write(to: directory)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: directory.appending(path: RecordingManifest.fileName))
        XCTAssertEqual(try decoder.decode(RecordingManifest.self, from: data), manifest)
    }

    /// The fallback recording is the one that must not be taken at face value later: echo
    /// cancellation is off, so the microphone track holds both sides of the call and cannot
    /// be labelled "me". The manifest is the only place that survives to say so.
    func testAMixedTrackAndTheReasonForItAreBothPersisted() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "Manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = RecordingManifest(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            reports: [report("mic", hostTime: 1_000, content: .mixed)],
            warning: "the system audio tap did not start"
        )
        try manifest.write(to: directory)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: directory.appending(path: RecordingManifest.fileName))
        let decoded = try decoder.decode(RecordingManifest.self, from: data)

        XCTAssertEqual(decoded.status, .completed, "a degraded session still completed")
        XCTAssertEqual(decoded.warning, "the system audio tap did not start")
        XCTAssertEqual(decoded.tracks.first?.content, .mixed)
    }

    func testEachCapturePathDeclaresWhoIsOnItsTrack() throws {
        let manifest = RecordingManifest(
            startedAt: Date(timeIntervalSince1970: 0),
            reports: [
                report("mic", hostTime: 1_000, content: .local),
                report("system", hostTime: 1_000, content: .remote),
            ]
        )

        XCTAssertEqual(manifest.tracks.first { $0.file == "mic.wav" }?.content, .local)
        XCTAssertEqual(manifest.tracks.first { $0.file == "system.wav" }?.content, .remote)
        XCTAssertNil(manifest.warning)
    }

    /// A recording made before the field existed does not get a guess: nothing in a finished
    /// file says whether echo cancellation was applied to it.
    func testLegacyTrackWithoutContentDecodesAsUnknown() throws {
        let json = """
            {
              "startedAt": "2023-11-14T22:13:20Z",
              "status": "completed",
              "tracks": [
                {
                  "file": "mic.wav",
                  "sampleRate": 48000,
                  "frameCount": 48000,
                  "peakAmplitude": 0.5,
                  "droppedSampleCount": 0
                }
              ]
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(RecordingManifest.self, from: Data(json.utf8))

        XCTAssertNil(manifest.tracks.first?.content)
        XCTAssertNil(manifest.warning)
    }

    func testLegacyManifestWithoutStatusDecodesAsCompleted() throws {
        let json = """
            {
              "startedAt": "2023-11-14T22:13:20Z",
              "tracks": []
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(RecordingManifest.self, from: Data(json.utf8))

        XCTAssertEqual(manifest.status, .completed)
        XCTAssertEqual(manifest.tracks, [])
        XCTAssertNil(manifest.failure)
    }

    func testLegacyFailedManifestWithoutStatusDecodesAsFailed() throws {
        let json = """
            {
              "startedAt": "2023-11-14T22:13:20Z",
              "tracks": [],
              "failure": "capture stopped"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(RecordingManifest.self, from: Data(json.utf8))

        XCTAssertEqual(manifest.status, .failed)
        XCTAssertEqual(manifest.failure, "capture stopped")
    }
}
