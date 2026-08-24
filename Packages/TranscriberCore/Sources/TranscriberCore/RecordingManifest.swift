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
    }

    public struct Track: Codable, Equatable, Sendable {
        public let file: String
        public let sampleRate: Double
        public let frameCount: Int
        public let peakAmplitude: Float
        public let droppedSampleCount: Int
        public let failure: String?

        /// Seconds from the recording's origin — the earliest first sample of any track —
        /// to this track's first sample. `nil` means the track never received a sample.
        public let startOffset: TimeInterval?

        /// Who is on the track. `nil` only in manifests written before the field existed:
        /// for those recordings it is genuinely unknown, and guessing from the file name
        /// would reintroduce exactly the claim this field was added to stop making.
        public let content: TrackContent?
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
