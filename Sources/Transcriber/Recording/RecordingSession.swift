import Foundation

/// One meeting's recording: a directory holding the two tracks.
///
/// Microphone and system audio are kept in separate files on purpose — the split is what
/// makes "me" versus "everyone else" exact rather than a guess. Nothing in the pipeline
/// may merge them.
struct RecordingSession: Equatable, Sendable {
    let directory: URL
    let startedAt: Date

    var microphoneTrackURL: URL { directory.appending(path: "mic.wav") }
    var systemTrackURL: URL { directory.appending(path: "system.wav") }

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
        let directory = root.appending(
            path: directoryName(for: startedAt),
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return RecordingSession(directory: directory, startedAt: startedAt)
    }
}
