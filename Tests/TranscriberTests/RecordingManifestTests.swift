import XCTest

@testable import Transcriber

final class RecordingManifestTests: XCTestCase {
    private func summary(
        _ label: String,
        hostTime: UInt64?,
        frameCount: Int = 48_000
    ) -> TrackRecorder.Summary {
        TrackRecorder.Summary(
            label: label,
            url: URL(fileURLWithPath: "/tmp/\(label).wav"),
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
            summaries: [
                summary("mic", hostTime: 1_000 + second),
                summary("system", hostTime: 1_000),
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
            summaries: [summary("mic", hostTime: 5_000), summary("system", hostTime: nil)]
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
            summaries: [summary("mic", hostTime: 1_000), summary("system", hostTime: 1_000)],
            failure: "capture stopped"
        )
        XCTAssertEqual(manifest.status, .failed)
        try manifest.write(to: directory)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: directory.appending(path: RecordingManifest.fileName))
        XCTAssertEqual(try decoder.decode(RecordingManifest.self, from: data), manifest)
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
