import Foundation
import TalkloomCore
import Testing

/// The shape a crash leaves behind, and what recovery is allowed to say about it.
@Suite("Session recovery")
final class SessionRecoveryTests {
    private let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "SessionRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Exactly what a killed process leaves: a header written by `init` that still declares
    /// zero bytes, with the samples on disk behind it. Writing the file properly and then
    /// zeroing the two size fields reproduces that byte for byte, and does it without
    /// depending on when a writer happens to be deallocated.
    @discardableResult
    private func crashedTrack(
        _ name: String,
        in directory: URL,
        frameCount: Int = 1_000,
        sampleRate: Int = 48_000,
        trailingByte: Bool = false
    ) throws -> URL {
        let url = directory.appending(path: name)
        let writer = try WAVWriter(url: url, sampleRate: sampleRate, channelCount: 1)
        try [Int16](repeating: 4_096, count: frameCount).withUnsafeBufferPointer {
            try writer.append($0)
        }
        try writer.finish()

        var bytes = try Data(contentsOf: url)
        // A torn final write: half a frame that the crash never finished.
        if trailingByte { bytes.append(0x7F) }
        bytes.replaceSubrange(4..<8, with: Data(repeating: 0, count: 4))
        bytes.replaceSubrange(40..<44, with: Data(repeating: 0, count: 4))
        try bytes.write(to: url)
        return url
    }

    private func session(
        _ name: String,
        manifest: RecordingManifest?,
        tracks: [String] = ["mic.wav", "system.wav"]
    ) throws -> URL {
        let directory = root.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest?.write(to: directory)
        for track in tracks { try crashedTrack(track, in: directory) }
        return directory
    }

    private func manifest(in directory: URL) throws -> RecordingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            RecordingManifest.self,
            from: Data(contentsOf: directory.appending(path: RecordingManifest.fileName)))
    }

    private func declaredDataByteCount(of url: URL) throws -> Int {
        let header = try Data(contentsOf: url).prefix(44)
        return header[40..<44].reversed().reduce(0) { ($0 << 8) | Int($1) }
    }

    // MARK: - The header

    @Test("a header still claiming zero bytes is repaired from the file's own length")
    func aZeroedHeaderIsRepairedFromTheFileLength() throws {
        let url = try crashedTrack("mic.wav", in: root, frameCount: 1_000)
        #expect(try declaredDataByteCount(of: url) == 0)

        let info = try WAVFile.repairSizes(at: url)

        #expect(info.wasRepaired)
        #expect(info.frameCount == 1_000)
        #expect(info.sampleRate == 48_000)
        #expect(info.channelCount == 1)
        #expect(try declaredDataByteCount(of: url) == 2_000)
        // Repairing a repaired file changes nothing, so a second launch is not a second
        // rewrite of everything the user has ever recorded.
        #expect(try !WAVFile.repairSizes(at: url).wasRepaired)
    }

    /// A write torn by the crash itself leaves half a frame. Rounding it up would hand a
    /// reader a frame built from one real byte and one imagined one.
    @Test("a half-written final frame stays outside the data chunk")
    func aTornFinalFrameIsLeftOut() throws {
        let url = try crashedTrack("mic.wav", in: root, frameCount: 1_000, trailingByte: true)

        let info = try WAVFile.repairSizes(at: url)

        #expect(info.frameCount == 1_000)
        #expect(try declaredDataByteCount(of: url) == 2_000)
    }

    @Test("a file that is not this app's WAV is refused rather than rewritten")
    func aForeignFileIsRefused() throws {
        let foreign = root.appending(path: "foreign.wav")
        try Data(repeating: 0x41, count: 96).write(to: foreign)
        let short = root.appending(path: "short.wav")
        try Data(repeating: 0x41, count: 8).write(to: short)

        #expect(throws: WAVFile.Failure.unsupportedLayout(name: "foreign.wav")) {
            try WAVFile.repairSizes(at: foreign)
        }
        #expect(throws: WAVFile.Failure.truncated(name: "short.wav")) {
            try WAVFile.repairSizes(at: short)
        }
    }

    // MARK: - The session

    /// The interrupted session is the one that says `recording`; the finished ones beside
    /// it are not touched, however unfinished their files may look.
    @Test("an interrupted session is repaired and a finished one is left alone")
    func onlyInterruptedSessionsAreRepaired() throws {
        let interrupted = try session(
            "2026-01-01_10-00-00",
            manifest: .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        let finished = try session(
            "2026-01-02_10-00-00",
            manifest: RecordingManifest(startedAt: Date(timeIntervalSince1970: 2_000), reports: []),
            tracks: ["mic.wav"])

        let outcomes = SessionRecovery.recoverInterrupted(in: root)

        // Compared by name: `contentsOfDirectory` hands back resolved, trailing-slash URLs.
        #expect(outcomes.map(\.directory.lastPathComponent) == [interrupted.lastPathComponent])
        #expect(outcomes.first?.repairedTracks == ["mic.wav", "system.wav"])
        #expect(outcomes.first?.failure == nil)

        let repaired = try manifest(in: interrupted)
        #expect(repaired.status == .interrupted)
        #expect(repaired.startedAt == Date(timeIntervalSince1970: 1_000))
        #expect(repaired.tracks.map(\.file) == ["mic.wav", "system.wav"])
        #expect(repaired.tracks.allSatisfy { $0.frameCount == 1_000 })
        #expect(repaired.failure?.contains("Alignment is unavailable") == true)
        #expect(try declaredDataByteCount(of: interrupted.appending(path: "mic.wav")) == 2_000)

        // Nothing that was never measured is now claimed to have been.
        #expect(repaired.tracks.allSatisfy { $0.peakAmplitude == nil })
        #expect(repaired.tracks.allSatisfy { $0.droppedSampleCount == nil })
        #expect(repaired.tracks.allSatisfy { $0.startOffset == nil })
        #expect(repaired.tracks.allSatisfy { $0.content == nil })

        // The finished session keeps its own account of itself, broken header and all.
        #expect(try manifest(in: finished).status == .completed)
        #expect(try declaredDataByteCount(of: finished.appending(path: "mic.wav")) == 0)

        // Recovery is not a state the app has to remember: the second pass finds nothing.
        #expect(SessionRecovery.recoverInterrupted(in: root).isEmpty)
    }

    /// The two host times came from one machine clock before the crash. Their absolute
    /// values do not survive as part of the finished format; their difference does.
    @Test("a recovered session retains checkpointed track alignment")
    func recoveredSessionRetainsCheckpointedTrackAlignment() throws {
        let second = HostTime.hostTicks(forSeconds: 0.75)
        let checkpointManifest = RecordingManifest.recording(
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        .checkpointingFirstSample(file: "system.wav", hostTime: 1_000)
        .checkpointingFirstSample(file: "mic.wav", hostTime: 1_000 + second)
        let directory = try session("2026-01-02_11-00-00", manifest: checkpointManifest)

        _ = SessionRecovery.recoverInterrupted(in: root)

        let recovered = try manifest(in: directory)
        let mic = try #require(recovered.tracks.first { $0.file == "mic.wav" })
        let system = try #require(recovered.tracks.first { $0.file == "system.wav" })
        #expect(recovered.status == .interrupted)
        #expect(system.startOffset == 0)
        #expect(abs(try #require(mic.startOffset) - 0.75) < 0.001)
        #expect(recovered.failure?.contains("Alignment is unavailable") == false)
        #expect(recovered.trackStarts.isEmpty, "raw host times are replaced by offsets")
    }

    /// Sessions recorded before the in-progress manifest existed have no `session.json`, and
    /// a crash can also truncate the one that is there. Both are still recordings.
    @Test("a missing or unreadable manifest is recovered as the legacy shape")
    func aMissingOrUnreadableManifestIsRecovered() throws {
        let legacy = try session("2026-01-03_10-00-00", manifest: nil, tracks: ["mic.wav"])
        let truncated = try session("2026-01-04_10-00-00", manifest: nil, tracks: ["mic.wav"])
        try Data("{\"startedAt\":".utf8)
            .write(to: truncated.appending(path: RecordingManifest.fileName))

        let outcomes = SessionRecovery.recoverInterrupted(in: root)

        #expect(
            outcomes.map(\.directory.lastPathComponent)
                == [legacy.lastPathComponent, truncated.lastPathComponent])
        for directory in [legacy, truncated] {
            let repaired = try manifest(in: directory)
            #expect(repaired.status == .interrupted)
            #expect(repaired.tracks.first?.frameCount == 1_000)
        }
    }

    /// A track that cannot be repaired is named rather than dropped: the rest of the
    /// session is still worth having, and the part that is not is worth knowing about.
    @Test("a track that cannot be repaired is reported and the session still is")
    func anUnrepairableTrackIsReported() throws {
        let directory = try session(
            "2026-01-05_10-00-00",
            manifest: .recording(startedAt: Date(timeIntervalSince1970: 1_000)),
            tracks: ["mic.wav"])
        try Data(repeating: 0x41, count: 96).write(to: directory.appending(path: "system.wav"))

        let outcome = try #require(SessionRecovery.recoverInterrupted(in: root).first)

        #expect(outcome.repairedTracks == ["mic.wav"])
        #expect(outcome.failure?.contains("system.wav") == true)
        let repaired = try manifest(in: directory)
        #expect(repaired.tracks.map(\.file) == ["mic.wav"])
        #expect(repaired.failure?.contains("system.wav") == true)
    }
}
