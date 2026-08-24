import Foundation

/// Finds recordings the app never finished, and makes them readable again.
///
/// A session writes its manifest with `status == recording` before capture starts and
/// replaces it when it stops, so a crash, a kill or a logout leaves that first manifest in
/// place next to two WAV files whose headers still declare zero bytes. Nothing about that
/// directory is broken except four bytes per file — but every reader, from `afconvert` to
/// the transcription step that does not exist yet, sees an empty recording.
///
/// Recovery is keyed on the manifest's status rather than on its absence. Absence is the
/// legacy shape: sessions recorded before the in-progress manifest existed have no
/// `session.json` at all, and they get the same treatment.
///
/// What it deliberately does not do is reconstruct what was never measured. The repaired
/// manifest says how long each track is and nothing else — no peak, no drop count, no
/// alignment between the tracks, no statement about who is on them. Track alignment in
/// particular only ever existed in memory, so a recovered session cannot be merged by
/// timestamp, and saying otherwise would be inventing the number that matters most.
public enum SessionRecovery {
    public struct Outcome: Equatable, Sendable {
        public let directory: URL

        /// Track files whose header disagreed with the file and was rewritten.
        public let repairedTracks: [String]

        /// Why this directory could not be recovered, if it could not.
        public let failure: String?
    }

    /// What a recovered session's manifest says instead of a stop.
    static let interruptionReason =
        "The app stopped while this session was recording. The tracks were repaired from "
        + "their length; the alignment between them was never written down and is unknown."

    /// Repairs every interrupted session under `root`, oldest directory name first.
    ///
    /// Sessions that finished — `completed`, `failed`, or an already recovered
    /// `interrupted` — are left untouched, so running this twice changes nothing the second
    /// time. A directory it cannot read is reported rather than skipped silently: a
    /// recording that cannot be repaired is exactly the one worth mentioning.
    public static func recoverInterrupted(
        in root: URL,
        fileManager: FileManager = .default
    ) -> [Outcome] {
        let entries =
            (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        return
            entries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { entry in
                guard
                    (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                    let startedAt = interruptedStart(of: entry, fileManager: fileManager)
                else { return nil }
                return recover(entry, startedAt: startedAt, fileManager: fileManager)
            }
    }

    /// When an unfinished session started, or `nil` if this directory is not one.
    private static func interruptedStart(of directory: URL, fileManager: FileManager) -> Date? {
        let manifestURL = directory.appending(path: RecordingManifest.fileName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            // No manifest at all: a session from before the in-progress manifest existed.
            // The directory was reserved when recording began, so its own creation date is
            // the closest thing to a start time that was actually recorded.
            return creationDate(of: directory, fileManager: fileManager)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(RecordingManifest.self, from: data) else {
            // Present but unreadable — a manifest truncated by the same crash. The tracks
            // beside it are still worth repairing.
            return creationDate(of: directory, fileManager: fileManager)
        }
        return manifest.status == .recording ? manifest.startedAt : nil
    }

    private static func creationDate(of directory: URL, fileManager: FileManager) -> Date? {
        (try? directory.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            ?? (try? fileManager.attributesOfItem(atPath: directory.path)[.creationDate]) as? Date
    }

    private static func recover(
        _ directory: URL,
        startedAt: Date,
        fileManager: FileManager
    ) -> Outcome {
        let tracks =
            ((try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var entries: [RecordingManifest.Track] = []
        var repaired: [String] = []
        var failures: [String] = []

        for track in tracks {
            do {
                let info = try WAVFile.repairSizes(at: track)
                if info.wasRepaired { repaired.append(track.lastPathComponent) }
                entries.append(
                    .recovered(
                        file: track.lastPathComponent,
                        sampleRate: Double(info.sampleRate),
                        frameCount: info.frameCount
                    ))
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        do {
            try RecordingManifest.interrupted(
                startedAt: startedAt,
                tracks: entries,
                failure: ([interruptionReason] + failures).joined(separator: " ")
            )
            .write(to: directory)
        } catch {
            failures.append(
                "The repaired session could not be described on disk: "
                    + error.localizedDescription)
        }

        return Outcome(
            directory: directory,
            repairedTracks: repaired,
            failure: failures.isEmpty ? nil : failures.joined(separator: " ")
        )
    }
}
