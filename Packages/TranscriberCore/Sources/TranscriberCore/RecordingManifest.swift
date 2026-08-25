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
        /// One uninterrupted run of captured samples in the master file.
        ///
        /// `startOffset` is derived from the span's hardware host-time anchor and is relative
        /// to the earliest master start in the session. `fileFrameOffset` includes any
        /// native-rate silence inserted before this span, so the encoded spans and the track's
        /// total `frameCount` make every leading, intermediate and trailing gap unambiguous.
        public struct Span: Codable, Equatable, Sendable {
            public let startOffset: TimeInterval
            public let fileFrameOffset: Int
            public let frameCount: Int

            public init(
                startOffset: TimeInterval,
                fileFrameOffset: Int,
                frameCount: Int
            ) {
                self.startOffset = startOffset
                self.fileFrameOffset = fileFrameOffset
                self.frameCount = frameCount
            }
        }

        /// Native-rate silence in the master. This is derived from the encoded span
        /// boundaries rather than stored a second time in `session.json`.
        public struct Gap: Equatable, Sendable {
            public let fileFrameOffset: Int
            public let frameCount: Int

            public var duration: TimeInterval { Double(frameCount) / sampleRate }

            private let sampleRate: Double

            fileprivate init(fileFrameOffset: Int, frameCount: Int, sampleRate: Double) {
                self.fileFrameOffset = fileFrameOffset
                self.frameCount = frameCount
                self.sampleRate = sampleRate
            }
        }

        public let file: String
        public let source: TrackSource?
        public let segmentIndex: Int?
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

        /// Measured uninterrupted sample runs. `nil` means an older or recovered recording
        /// did not preserve enough information to distinguish audio from gaps.
        public let spans: [Span]?

        /// Seconds from the session origin to frame zero of this master. It can precede the
        /// first real span when an initial dropped block was replaced with silence.
        public let startOffset: TimeInterval?

        /// Every region of native-rate silence not covered by a measured span.
        ///
        /// `nil` means the span topology is unknown. An empty array means it was measured
        /// and the master is continuous.
        public var gaps: [Gap]? {
            guard let spans else { return nil }
            var result: [Gap] = []
            var nextFrame = 0
            for span in spans {
                if span.fileFrameOffset > nextFrame {
                    result.append(
                        Gap(
                            fileFrameOffset: nextFrame,
                            frameCount: span.fileFrameOffset - nextFrame,
                            sampleRate: sampleRate
                        ))
                }
                nextFrame = max(nextFrame, span.fileFrameOffset + span.frameCount)
            }
            if frameCount > nextFrame {
                result.append(
                    Gap(
                        fileFrameOffset: nextFrame,
                        frameCount: frameCount - nextFrame,
                        sampleRate: sampleRate
                    ))
            }
            return result
        }

        /// Who is on the track. `nil` only in manifests written before the field existed,
        /// and in recovered sessions: for those recordings it is genuinely unknown, and
        /// guessing from the file name would reintroduce exactly the claim this field was
        /// added to stop making.
        public let content: TrackContent?

        private enum CodingKeys: String, CodingKey {
            case file
            case source
            case segmentIndex
            case sampleRate
            case frameCount
            case peakAmplitude
            case droppedSampleCount
            case failure
            case spans
            case startOffset
            case content
        }

        fileprivate init(
            file: String,
            source: TrackSource?,
            segmentIndex: Int?,
            sampleRate: Double,
            frameCount: Int,
            peakAmplitude: Float?,
            droppedSampleCount: Int?,
            failure: String?,
            spans: [Span]?,
            startOffset: TimeInterval?,
            content: TrackContent?
        ) {
            self.file = file
            self.source = source
            self.segmentIndex = segmentIndex
            self.sampleRate = sampleRate
            self.frameCount = frameCount
            self.peakAmplitude = peakAmplitude
            self.droppedSampleCount = droppedSampleCount
            self.failure = failure
            self.spans = spans
            self.startOffset = startOffset
            self.content = content
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            file = try container.decode(String.self, forKey: .file)
            source = try container.decodeIfPresent(TrackSource.self, forKey: .source)
            segmentIndex = try container.decodeIfPresent(Int.self, forKey: .segmentIndex)
            sampleRate = try container.decode(Double.self, forKey: .sampleRate)
            frameCount = try container.decode(Int.self, forKey: .frameCount)
            peakAmplitude = try container.decodeIfPresent(Float.self, forKey: .peakAmplitude)
            droppedSampleCount = try container.decodeIfPresent(
                Int.self, forKey: .droppedSampleCount)
            failure = try container.decodeIfPresent(String.self, forKey: .failure)
            content = try container.decodeIfPresent(TrackContent.self, forKey: .content)
            startOffset = try container.decodeIfPresent(TimeInterval.self, forKey: .startOffset)

            if container.contains(.spans) {
                spans = try container.decodeIfPresent([Span].self, forKey: .spans)
            } else if let startOffset {
                spans = [
                    Span(
                        startOffset: startOffset,
                        fileFrameOffset: 0,
                        frameCount: frameCount)
                ]
            } else {
                spans = nil
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(file, forKey: .file)
            try container.encodeIfPresent(source, forKey: .source)
            try container.encodeIfPresent(segmentIndex, forKey: .segmentIndex)
            try container.encode(sampleRate, forKey: .sampleRate)
            try container.encode(frameCount, forKey: .frameCount)
            try container.encodeIfPresent(peakAmplitude, forKey: .peakAmplitude)
            try container.encodeIfPresent(droppedSampleCount, forKey: .droppedSampleCount)
            try container.encodeIfPresent(failure, forKey: .failure)
            try container.encode(spans, forKey: .spans)
            try container.encodeIfPresent(startOffset, forKey: .startOffset)
            try container.encodeIfPresent(content, forKey: .content)
        }

        /// A track found on disk after an interrupted session. Its length comes from the
        /// file; everything else was never written down, so it stays unknown rather than
        /// being reconstructed into something that looks measured.
        static func recovered(
            file: String,
            sampleRate: Double,
            frameCount: Int,
            startOffset: TimeInterval?
        ) -> Track {
            Track(
                file: file,
                source: nil,
                segmentIndex: nil,
                sampleRate: sampleRate,
                frameCount: frameCount,
                peakAmplitude: nil,
                droppedSampleCount: nil,
                failure: nil,
                spans: nil,
                startOffset: startOffset,
                content: nil
            )
        }
    }

    /// A first-sample timestamp checkpointed while capture is still running.
    ///
    /// A mach host time is meaningful here only relative to another track from the same
    /// recording. The finished manifest stores those differences as the master and span
    /// offsets; the raw values exist only long enough to survive an interrupted recording.
    public struct TrackStart: Codable, Equatable, Sendable {
        public let file: String
        public let hostTime: UInt64

        public init(file: String, hostTime: UInt64) {
            self.file = file
            self.hostTime = hostTime
        }
    }

    public let startedAt: Date
    public let status: Status
    public let tracks: [Track]
    public let failure: String?

    /// First samples observed before finalization. Empty on a finished session.
    public let trackStarts: [TrackStart]

    /// Why a session that completed is not the session that was asked for — the system tap
    /// failing to start, and the microphone therefore recording both sides without echo
    /// cancellation. It lived only in the menu bar until now, which meant it was gone by the
    /// next recording, while the file it describes stayed on disk.
    public let warning: String?

    public static let fileName = "session.json"

    /// Physical master segments in their logical-track order.
    public func segments(for source: TrackSource) -> [Track] {
        tracks
            .filter { $0.source == source }
            .sorted { ($0.segmentIndex ?? .max) < ($1.segmentIndex ?? .max) }
    }

    private init(
        startedAt: Date,
        status: Status,
        tracks: [Track],
        failure: String?,
        warning: String?,
        trackStarts: [TrackStart] = []
    ) {
        self.startedAt = startedAt
        self.status = status
        self.tracks = tracks
        self.failure = failure
        self.warning = warning
        self.trackStarts = trackStarts
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

    /// Returns the in-progress manifest with one track's first sample checkpointed.
    /// Repeated reports cannot replace the first timestamp that already reached disk.
    public func checkpointingFirstSample(file: String, hostTime: UInt64) -> RecordingManifest {
        guard status == .recording, hostTime != 0,
            !trackStarts.contains(where: { $0.file == file })
        else { return self }

        return RecordingManifest(
            startedAt: startedAt,
            status: status,
            tracks: tracks,
            failure: failure,
            warning: warning,
            trackStarts: (trackStarts + [TrackStart(file: file, hostTime: hostTime)])
                .sorted { $0.file < $1.file }
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
        trackStarts = []
        status = failure == nil ? .completed : .failed
        let origin = reports.compactMap(\.firstSampleHostTime).min()
        tracks = reports.map { report in
            let startOffset = report.firstSampleHostTime.flatMap { first in
                origin.map { HostTime.seconds(from: $0, to: first) }
            }
            let spans = report.spans.map { reportSpans in
                reportSpans.compactMap { span in
                    origin.map {
                        Track.Span(
                            startOffset: HostTime.seconds(from: $0, to: span.startHostTime),
                            fileFrameOffset: span.fileFrameOffset,
                            frameCount: span.frameCount
                        )
                    }
                }
            }
            return Track(
                file: report.file,
                source: report.source,
                segmentIndex: report.segmentIndex,
                sampleRate: report.sampleRate,
                frameCount: report.frameCount,
                peakAmplitude: report.peakAmplitude,
                droppedSampleCount: report.droppedSampleCount,
                failure: report.failure,
                spans: spans,
                startOffset: startOffset,
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
        trackStarts = try container.decodeIfPresent([TrackStart].self, forKey: .trackStarts) ?? []
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
