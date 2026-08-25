import Foundation

/// One bounded, finished audio chunk presented to an ASR implementation.
///
/// The file is a derived 16 kHz mono Int16 WAV, never a capture master. `startOffset`
/// places its local timestamps on the meeting timeline, `duration` bounds provider timestamps,
/// and `source` preserves the exact channel-of-origin speaker split.
public struct TranscriptionChunk: Equatable, Sendable {
    public let audioURL: URL
    public let startOffset: TimeInterval
    public let duration: TimeInterval
    public let source: TrackSource

    public init(
        audioURL: URL,
        startOffset: TimeInterval,
        duration: TimeInterval,
        source: TrackSource
    ) {
        self.audioURL = audioURL
        self.startOffset = startOffset
        self.duration = duration
        self.source = source
    }
}

public enum TranscriptLanguage: String, Codable, Equatable, Sendable {
    case russian = "ru"
    case english = "en"
    case mixed
    case unknown
}

/// A timestamped utterance on the meeting timeline.
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String
    public let language: TranscriptLanguage
    public let source: TrackSource

    public init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        language: TranscriptLanguage,
        source: TrackSource
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.language = language
        self.source = source
    }
}

/// Provider usage retained with the result so cost and speed can be evaluated rather than
/// inferred from a dashboard after the fact.
public struct TranscriptionUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let cost: Double?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        cost: Double? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cost = cost
    }
}

public struct TranscriptionResult: Codable, Equatable, Sendable {
    public let model: String
    public let segments: [TranscriptSegment]
    public let usage: TranscriptionUsage?

    public init(
        model: String,
        segments: [TranscriptSegment],
        usage: TranscriptionUsage? = nil
    ) {
        self.model = model
        self.segments = segments
        self.usage = usage
    }
}

/// The seam shared by cloud and local ASR engines.
public protocol Transcriber: Sendable {
    func transcribe(_ chunk: TranscriptionChunk) async throws -> TranscriptionResult
}
