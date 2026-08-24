import XCTest

@testable import Transcriber

final class RecordingSessionTests: XCTestCase {
    func testDirectoryNameIsSortableAndFilesystemSafe() {
        let date = Date(timeIntervalSince1970: 1_756_045_812)  // 2025-08-24 14:30:12 UTC
        let name = RecordingSession.directoryName(for: date, timeZone: TimeZone(identifier: "UTC")!)

        XCTAssertEqual(name, "2025-08-24_14-30-12")
        // Finder renders a colon in a filename as a slash, so the time must not use one.
        XCTAssertFalse(name.contains(":"))
    }

    func testDirectoryNamesSortChronologically() {
        let utc = TimeZone(identifier: "UTC")!
        let earlier = RecordingSession.directoryName(
            for: Date(timeIntervalSince1970: 1_000_000), timeZone: utc)
        let later = RecordingSession.directoryName(
            for: Date(timeIntervalSince1970: 2_000_000), timeZone: utc)

        XCTAssertLessThan(earlier, later)
    }

    func testCreateMakesTheDirectoryAndTrackURLsDiffer() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "TranscriberTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let startedAt = Date(timeIntervalSince1970: 1_756_045_812)

        let session = try RecordingSession.create(startedAt: startedAt, root: root)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: session.directory.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)

        // The two tracks are never the same file: keeping them apart is what makes
        // "me" versus "everyone else" exact.
        XCTAssertNotEqual(session.microphoneTrackURL, session.systemTrackURL)
        XCTAssertEqual(session.microphoneTrackURL.lastPathComponent, "mic.wav")
        XCTAssertEqual(session.systemTrackURL.lastPathComponent, "system.wav")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(
            contentsOf: session.directory.appending(path: RecordingManifest.fileName))
        let manifest = try decoder.decode(RecordingManifest.self, from: data)
        XCTAssertEqual(manifest.startedAt, session.startedAt)
        XCTAssertEqual(manifest.status, .recording)
        XCTAssertEqual(manifest.tracks, [])
        XCTAssertNil(manifest.failure)
    }

    func testTwoSessionsStartedInTheSameSecondUseDifferentDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "TranscriberTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let startedAt = Date(timeIntervalSince1970: 1_756_045_812)

        let first = try RecordingSession.create(startedAt: startedAt, root: root)
        let second = try RecordingSession.create(startedAt: startedAt, root: root)

        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertEqual(second.directory.lastPathComponent, "\(first.directory.lastPathComponent)-2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directory.path))
    }
}
