import Foundation

/// What a recording consists of, written next to the tracks as `session.json`.
///
/// The tracks do not start together — the microphone's echo canceller takes the best part
/// of a second to produce its first sample, while the tap produces one immediately — so
/// merging them by timestamp needs the offset, and the offset is not in the audio. Keeping
/// it here rather than only in the log means the recording explains itself to whatever
/// reads it next, including the analysis scripts.
public struct RecordingManifest: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case recording
        case completed
        case failed

        /// The app stopped while this session was recording, and the tracks were repaired
        /// from their length afterwards. Distinct from `failed`, which describes a session
        /// that ran to its own end and reported why it went wrong: here nothing reported
        /// anything, and most of what the manifest would normally say is simply unknown.
        case interrupted
    }

    public struct Track: Codable, Equatable, Sendable {
        public let file: String
        public let sampleRate: Double
        public let frameCount: Int

        /// What the recorder measured, or `nil` when nobody measured it — a recovered track
        /// has the audio but no measurement, and reading a peak out of the file afterwards
        /// would be a different claim from the one this field makes.
        public let peakAmplitude: Float?

        /// Samples the producer had to throw away, or `nil` when it was never recorded.
        /// Zero means the drop counter was read and stood at zero; `nil` means nothing read
        /// it, which is what an interrupted session leaves behind.
        public let droppedSampleCount: Int?

        public let failure: String?

        /// Seconds from the recording's origin — the earliest first sample of any track —
        /// to this track's first sample. `nil` means the track never received a sample.
        public let startOffset: TimeInterval?

        /// Who is on the track. `nil` only in manifests written before the field existed,
        /// and in recovered sessions: for those recordings it is genuinely unknown, and
        /// guessing from the file name would reintroduce exactly the claim this field was
        /// added to stop making.
        public let content: TrackContent?

        /// A track found on disk after an interrupted session. Its length comes from the
        /// file; everything else was never written down, so it stays unknown rather than
        /// being reconstructed into something that looks measured.
        static func recovered(file: String, sampleRate: Double, frameCount: Int) -> Track {
            Track(
                file: file,
                sampleRate: sampleRate,
                frameCount: frameCount,
                peakAmplitude: nil,
                droppedSampleCount: nil,
                failure: nil,
                startOffset: nil,
                content: nil
            )
        }
    }

    public let startedAt: Date
    public let status: Status
    public let tracks: [Track]
    public let failure: String?

    /// Why a session that completed is not the session that was asked for — the system tap
    /// failing to start, and the microphone therefore recording both sides without echo
    /// cancellation. It lived only in the menu bar until now, which meant it was gone by the
    /// next recording, while the file it describes stayed on disk.
    public let warning: String?

    public static let fileName = "session.json"

    private init(
        startedAt: Date,
        status: Status,
        tracks: [Track],
        failure: String?,
        warning: String?
    ) {
        self.startedAt = startedAt
        self.status = status
        self.tracks = tracks
        self.failure = failure
        self.warning = warning
    }

    /// Written as soon as the session directory is reserved. If the process dies before
    /// finalization, the directory remains self-identifying rather than looking like a
    /// successful session that mysteriously has no manifest.
    public static func recording(startedAt: Date) -> RecordingManifest {
        RecordingManifest(
            startedAt: startedAt,
            status: .recording,
            tracks: [],
            failure: nil,
            warning: nil
        )
    }

    /// Replaces the in-progress manifest of a session the app never got to finish.
    ///
    /// The tracks are what was found on disk and repaired, not what any recorder reported —
    /// nothing reported anything. The failure text is what the directory has instead of a
    /// stop, so whoever reads it later knows why the alignment is missing.
    static func interrupted(startedAt: Date, tracks: [Track], failure: String) -> RecordingManifest
    {
        RecordingManifest(
            startedAt: startedAt,
            status: .interrupted,
            tracks: tracks,
            failure: failure,
            warning: nil
        )
    }

    /// Builds a manifest from what the recorders reported, putting the tracks on a common
    /// timeline. Tracks that never received a sample carry no offset because there is
    /// nothing to align.
    public init(
        startedAt: Date,
        reports: [TrackReport],
        failure: String? = nil,
        warning: String? = nil
    ) {
        self.startedAt = startedAt
        self.failure = failure
        self.warning = warning
        status = failure == nil ? .completed : .failed
        let origin = reports.compactMap(\.firstSampleHostTime).min()
        tracks = reports.map { report in
            let offset = report.firstSampleHostTime.flatMap { first in
                origin.map { HostTime.seconds(from: $0, to: first) }
            }
            return Track(
                file: report.file,
                sampleRate: report.sampleRate,
                frameCount: report.frameCount,
                peakAmplitude: report.peakAmplitude,
                droppedSampleCount: report.droppedSampleCount,
                failure: report.failure,
                startOffset: offset,
                content: report.content
            )
        }
    }

    /// Manifests written before the status field existed describe finalized sessions.
    /// Defaulting only that legacy shape keeps existing recordings readable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        tracks = try container.decode([Track].self, forKey: .tracks)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        warning = try container.decodeIfPresent(String.self, forKey: .warning)
        status =
            try container.decodeIfPresent(Status.self, forKey: .status)
            ?? (failure == nil ? .completed : .failed)
    }

    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(
            to: directory.appending(path: Self.fileName), options: .atomic)
    }
}
