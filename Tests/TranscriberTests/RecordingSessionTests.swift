import Foundation
import Testing
import TranscriberCore

@testable import Transcriber

@Suite("Recording session")
struct RecordingSessionTests {
    private let utc = TimeZone(identifier: "UTC")!

    /// A directory that exists for one test and is removed with it.
    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "TranscriberTests-\(UUID().uuidString)")
    }

    @Test("the directory name is sortable and filesystem safe")
    func directoryNameIsSortableAndFilesystemSafe() {
        let date = Date(timeIntervalSince1970: 1_756_045_812)  // 2025-08-24 14:30:12 UTC
        let name = RecordingSession.directoryName(for: date, timeZone: utc)

        #expect(name == "2025-08-24_14-30-12")
        // Finder renders a colon in a filename as a slash, so the time must not use one.
        #expect(!name.contains(":"))
    }

    @Test("directory names sort chronologically")
    func directoryNamesSortChronologically() {
        let earlier = RecordingSession.directoryName(
            for: Date(timeIntervalSince1970: 1_000_000), timeZone: utc)
        let later = RecordingSession.directoryName(
            for: Date(timeIntervalSince1970: 2_000_000), timeZone: utc)

        #expect(earlier < later)
    }

    @Test("create makes the directory, and the track URLs differ")
    func createMakesTheDirectoryAndTrackURLsDiffer() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let startedAt = Date(timeIntervalSince1970: 1_756_045_812)

        let session = try RecordingSession.create(startedAt: startedAt, root: root)

        var isDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: session.directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        // The two tracks are never the same file: keeping them apart is what makes
        // "me" versus "everyone else" exact.
        #expect(session.microphoneTrackURL != session.systemTrackURL)
        #expect(session.microphoneTrackURL.lastPathComponent == "mic.wav")
        #expect(session.systemTrackURL.lastPathComponent == "system.wav")
        #expect(
            session.trackURL(for: .microphone, segmentIndex: 1).lastPathComponent
                == "mic-2.wav")
        #expect(
            session.trackURL(for: .systemAudio, segmentIndex: 2).lastPathComponent
                == "system-3.wav")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(
            contentsOf: session.directory.appending(path: RecordingManifest.fileName))
        let manifest = try decoder.decode(RecordingManifest.self, from: data)
        #expect(manifest.startedAt == session.startedAt)
        #expect(manifest.status == .recording)
        #expect(manifest.tracks == [])
        #expect(manifest.failure == nil)
    }

    @Test("two sessions started in the same second use different directories")
    func twoSessionsInTheSameSecondUseDifferentDirectories() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let startedAt = Date(timeIntervalSince1970: 1_756_045_812)

        let first = try RecordingSession.create(startedAt: startedAt, root: root)
        let second = try RecordingSession.create(startedAt: startedAt, root: root)

        #expect(first.directory != second.directory)
        #expect(second.directory.lastPathComponent == "\(first.directory.lastPathComponent)-2")
        #expect(FileManager.default.fileExists(atPath: first.directory.path))
        #expect(FileManager.default.fileExists(atPath: second.directory.path))
    }
}
