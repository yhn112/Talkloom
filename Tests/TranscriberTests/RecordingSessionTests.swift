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
        let earlier = RecordingSession.directoryName(for: Date(timeIntervalSince1970: 1_000_000), timeZone: utc)
        let later = RecordingSession.directoryName(for: Date(timeIntervalSince1970: 2_000_000), timeZone: utc)

        XCTAssertLessThan(earlier, later)
    }

    func testCreateMakesTheDirectoryAndTrackURLsDiffer() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "TranscriberTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try RecordingSession.create(root: root)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: session.directory.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)

        // The two tracks are never the same file: keeping them apart is what makes
        // "me" versus "everyone else" exact.
        XCTAssertNotEqual(session.microphoneTrackURL, session.systemTrackURL)
        XCTAssertEqual(session.microphoneTrackURL.lastPathComponent, "mic.wav")
        XCTAssertEqual(session.systemTrackURL.lastPathComponent, "system.wav")
    }
}
