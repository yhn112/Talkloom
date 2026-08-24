import Foundation

/// What a recording consists of, written next to the tracks as `session.json`.
///
/// The tracks do not start together — the microphone's echo canceller takes the best part
/// of a second to produce its first sample, while the tap produces one immediately — so
/// merging them by timestamp needs the offset, and the offset is not in the audio. Keeping
/// it here rather than only in the log means the recording explains itself to whatever
/// reads it next, including the analysis scripts.
struct RecordingManifest: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case recording
        case completed
        case failed
    }

    struct Track: Codable, Equatable, Sendable {
        let file: String
        let sampleRate: Double
        let frameCount: Int
        let peakAmplitude: Float
        let droppedSampleCount: Int
        let failure: String?

        /// Seconds from the recording's origin — the earliest first sample of any track —
        /// to this track's first sample. `nil` means the track never received a sample.
        let startOffset: TimeInterval?

    }

    let startedAt: Date
    let status: Status
    let tracks: [Track]
    let failure: String?

    static let fileName = "session.json"

    private init(startedAt: Date, status: Status, tracks: [Track], failure: String?) {
        self.startedAt = startedAt
        self.status = status
        self.tracks = tracks
        self.failure = failure
    }

    /// Written as soon as the session directory is reserved. If the process dies before
    /// finalization, the directory remains self-identifying rather than looking like a
    /// successful session that mysteriously has no manifest.
    static func recording(startedAt: Date) -> RecordingManifest {
        RecordingManifest(startedAt: startedAt, status: .recording, tracks: [], failure: nil)
    }

    /// Builds a manifest from what the recorders reported, putting the tracks on a common
    /// timeline. Tracks that never received a sample carry no offset because there is
    /// nothing to align.
    init(
        startedAt: Date,
        summaries: [TrackRecorder.Summary],
        failure: String? = nil
    ) {
        self.init(
            startedAt: startedAt,
            completions: summaries.map { TrackRecorder.Completion(summary: $0, failure: nil) },
            failure: failure
        )
    }

    init(
        startedAt: Date,
        completions: [TrackRecorder.Completion],
        failure: String? = nil
    ) {
        self.startedAt = startedAt
        self.failure = failure
        status = failure == nil ? .completed : .failed
        let summaries = completions.map(\.summary)
        let origin = summaries.compactMap(\.firstSampleHostTime).min()
        tracks = completions.map { completion in
            let summary = completion.summary
            let offset = summary.firstSampleHostTime.flatMap { first in
                origin.map { HostTime.seconds(from: $0, to: first) }
            }
            return Track(
                file: summary.url.lastPathComponent,
                sampleRate: summary.sampleRate,
                frameCount: summary.frameCount,
                peakAmplitude: summary.peakAmplitude,
                droppedSampleCount: summary.droppedSampleCount,
                failure: completion.failure?.localizedDescription,
                startOffset: offset
            )
        }
    }

    /// Manifests written before the status field existed describe finalized sessions.
    /// Defaulting only that legacy shape keeps existing recordings readable.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        tracks = try container.decode([Track].self, forKey: .tracks)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        status = try container.decodeIfPresent(Status.self, forKey: .status)
            ?? (failure == nil ? .completed : .failed)
    }

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: directory.appending(path: Self.fileName), options: .atomic)
    }
}
