import Foundation
import TranscriberCore

/// One meeting's recording: a directory holding the two tracks.
///
/// Microphone and system audio are kept in separate files on purpose — the split is what
/// makes "me" versus "everyone else" exact rather than a guess. Nothing in the pipeline
/// may merge them.
struct RecordingSession: Equatable, Sendable {
    let directory: URL
    let startedAt: Date

    /// The masters, written in the device's own format while recording. The 16 kHz mono
    /// copies ASR wants are derived from these afterwards, so a better model can later be
    /// re-run against the original audio rather than against a downsampled copy.
    var microphoneTrackURL: URL { trackURL(for: .microphone, segmentIndex: 0) }
    var systemTrackURL: URL { trackURL(for: .systemAudio, segmentIndex: 0) }

    func trackURL(for source: TrackSource, segmentIndex: Int) -> URL {
        let stem = source == .microphone ? "mic" : "system"
        let suffix = segmentIndex == 0 ? "" : "-\(segmentIndex + 1)"
        return directory.appending(path: "\(stem)\(suffix).wav")
    }

    /// Directory name for a session, e.g. `2026-08-24_15-30-12`.
    ///
    /// Sortable by name, safe on a case-insensitive filesystem, and free of colons, which
    /// Finder displays as slashes.
    static func directoryName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    /// Root for all recordings.
    ///
    /// Application Support rather than Documents: writing to Documents triggers a separate
    /// TCC prompt, and this app already asks for microphone and audio capture.
    static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appending(path: "Transcriber/Recordings", directoryHint: .isDirectory)
    }

    /// Creates the directory for a new session.
    static func create(
        startedAt: Date = Date(),
        root: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> RecordingSession {
        let root = try root ?? defaultRoot(fileManager: fileManager)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let baseName = directoryName(for: startedAt)
        var suffix = 1
        while true {
            let name = suffix == 1 ? baseName : "\(baseName)-\(suffix)"
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            do {
                // Creating the leaf without intermediates is the atomic reservation. Two
                // starts in the same second must never open the same mic.wav/system.wav.
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                suffix += 1
                continue
            }

            let session = RecordingSession(directory: directory, startedAt: startedAt)
            do {
                try RecordingManifest.recording(startedAt: startedAt).write(to: directory)
                return session
            } catch {
                try? fileManager.removeItem(at: directory)
                throw error
            }
        }
    }
}
