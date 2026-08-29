import AVFoundation
import Foundation
import TalkloomCore

/// What one evaluator writes to stdout for one fixture.
///
/// `scripts/asr-eval.sh` reads this shape, and it reads it the same way whichever engine
/// produced the text — which is the point. An engine measured through a different report
/// could not be compared with the recorded baseline, so the shape lives here once rather
/// than once per evaluator.
public struct EvaluationReport: Codable, Sendable {
    public let audioFile: String
    public let audioBytes: Int
    public let audioDurationSeconds: TimeInterval
    public let elapsedSeconds: TimeInterval
    public let realTimeFactor: Double
    public let result: TranscriptionResult

    public init(
        audio: EvaluationAudio,
        elapsedSeconds: TimeInterval,
        result: TranscriptionResult
    ) {
        audioFile = audio.url.lastPathComponent
        audioBytes = audio.byteCount
        audioDurationSeconds = audio.duration
        self.elapsedSeconds = elapsedSeconds
        realTimeFactor = elapsedSeconds / audio.duration
        self.result = result
    }

    public func write(to handle: FileHandle = .standardOutput) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        handle.write(try encoder.encode(self))
        handle.write(Data("\n".utf8))
    }
}

/// A fixture that has been proven to be in the project's canonical ASR format before any
/// engine is handed it. An engine measured on 44.1 kHz stereo would produce a number that
/// says nothing about the pipeline this project actually builds.
public struct EvaluationAudio: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case invalidAudio(String)
        case fileSizeUnavailable

        public var errorDescription: String? {
            switch self {
            case .invalidAudio(let reason):
                "The evaluation input must be a finished 16 kHz mono Int16 WAV: \(reason)"
            case .fileSizeUnavailable:
                "Could not determine the evaluation input size."
            }
        }
    }

    public let url: URL
    public let byteCount: Int
    public let duration: TimeInterval

    public init(validating url: URL) throws {
        self.url = url.standardizedFileURL

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: self.url)
        } catch {
            throw Failure.invalidAudio(error.localizedDescription)
        }
        let format = file.fileFormat
        guard format.sampleRate == Double(SessionAudio.sampleRate) else {
            throw Failure.invalidAudio("sample rate is \(format.sampleRate) Hz")
        }
        guard format.channelCount == 1 else {
            throw Failure.invalidAudio("channel count is \(format.channelCount)")
        }
        guard format.commonFormat == .pcmFormatInt16 else {
            throw Failure.invalidAudio("sample format is not Int16 PCM")
        }
        duration = TimeInterval(file.length) / format.sampleRate
        guard duration.isFinite, duration > 0 else {
            throw Failure.invalidAudio("duration is zero or invalid")
        }

        guard let byteCount = try self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw Failure.fileSizeUnavailable
        }
        self.byteCount = byteCount
    }
}

/// Wall-clock seconds from a `Duration`, which is what a real-time factor needs.
public func evaluationSeconds(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds)
        + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
}
