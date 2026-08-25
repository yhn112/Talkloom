import AVFoundation
import Foundation

/// One finished master converted into the format ASR consumes.
///
/// The master it came from is kept whole rather than copied field by field: everything about
/// the recording — who is on it, where it sits on the meeting timeline, what the capture path
/// measured — is already stated there, and restating it here would be a second copy to drift.
/// The derived file and its length are the only facts this type adds.
public struct DerivedTrack: Equatable, Sendable {
    public let master: RecordingManifest.Track
    public let audioURL: URL
    public let frameCount: Int

    public init(master: RecordingManifest.Track, audioURL: URL, frameCount: Int) {
        self.master = master
        self.audioURL = audioURL
        self.frameCount = frameCount
    }

    public var duration: TimeInterval {
        Double(frameCount) / Double(SessionAudio.sampleRate)
    }

    /// Seconds from the session origin to frame zero of this file, or `nil` when the master
    /// never carried an alignment — a recovered session whose start was never checkpointed.
    /// An unaligned track can still be transcribed; it cannot be merged with the other one.
    public var startOffset: TimeInterval? { master.startOffset }

    public var source: TrackSource? { master.source }
    public var content: TrackContent? { master.content }
}

/// Derives the ASR-format tracks of a completed session from its masters.
///
/// This is the conversion `AGENTS.md` reserves for finished files. It runs once per master,
/// over a file nothing is still writing to, so the resampler is allowed to declare the stream
/// finished and flush its delay line — the thing a live drain loop can never do.
///
/// Each master segment becomes its own derived file. A capture path that restarted produces
/// several, separated by wall-clock the recording does not contain, and concatenating them
/// would mean inventing that silence as audio. The timeline stays in the manifest, where it
/// is a measurement rather than a synthesized sample.
public enum SessionAudio {
    /// The canonical ASR sample rate, mono Int16 on disk.
    public static let sampleRate = 16_000

    /// Derived audio lives beside the masters, in its own directory, so that "everything the
    /// recorder wrote" and "everything that can be regenerated from it" are never the same
    /// list.
    public static let derivedDirectoryName = "derived"

    private static let converter = URL(filePath: "/usr/bin/afconvert")

    public struct Failure: Error, Equatable, Sendable {
        public enum Reason: Error, Equatable, Sendable {
            case masterMissing
            case converterFailed(status: Int32, message: String)
            case converterUnavailable(String)
            case derivedFileUnreadable(String)
            case unexpectedDerivedFormat(sampleRate: Double, channelCount: UInt32)
        }

        public let master: String
        public let reason: Reason

        public init(master: String, reason: Reason) {
            self.master = master
            self.reason = reason
        }
    }

    /// What one pass over a session's masters produced. A master that cannot be converted is
    /// named, and the tracks that converted stay usable: one broken file must not cost the
    /// meeting the side that recorded correctly.
    public struct Derivation: Equatable, Sendable {
        public let tracks: [DerivedTrack]
        public let failures: [Failure]

        public init(tracks: [DerivedTrack], failures: [Failure]) {
            self.tracks = tracks
            self.failures = failures
        }

        public var isComplete: Bool { failures.isEmpty }
    }

    public enum PreparationError: Error, LocalizedError, Equatable {
        case derivedDirectoryUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .derivedDirectoryUnavailable(let message):
                "Could not create the derived audio directory: \(message)"
            }
        }
    }

    /// Converts every master that holds samples. A master with no frames is not converted:
    /// there is nothing to transcribe, and `session.json` already records that it was empty.
    public static func derive(
        _ manifest: RecordingManifest,
        in directory: URL
    ) async throws -> Derivation {
        let derivedDirectory = directory.appending(path: derivedDirectoryName)
        do {
            try FileManager.default.createDirectory(
                at: derivedDirectory, withIntermediateDirectories: true)
        } catch {
            throw PreparationError.derivedDirectoryUnavailable(error.localizedDescription)
        }

        var tracks: [DerivedTrack] = []
        var failures: [Failure] = []

        for master in manifest.tracks where master.frameCount > 0 {
            let source = directory.appending(path: master.file)
            guard FileManager.default.fileExists(atPath: source.path) else {
                failures.append(Failure(master: master.file, reason: .masterMissing))
                continue
            }
            let destination = derivedDirectory.appending(path: derivedName(of: master.file))
            do {
                tracks.append(
                    DerivedTrack(
                        master: master,
                        audioURL: destination,
                        frameCount: try await convert(source, to: destination)))
            } catch let failure as Failure.Reason {
                failures.append(Failure(master: master.file, reason: failure))
            }
        }

        return Derivation(tracks: tracks, failures: failures)
    }

    static func derivedName(of master: String) -> String {
        let stem = (master as NSString).deletingPathExtension
        return "\(stem)-\(sampleRate / 1000)k.wav"
    }

    private static func convert(_ source: URL, to destination: URL) async throws -> Int {
        try? FileManager.default.removeItem(at: destination)

        let result = try await run([
            "-f", "WAVE",
            "-d", "LEI16@\(sampleRate)",
            "-c", "1",
            // The mastering-quality sample-rate converter at full quality. This runs once per
            // meeting over a finished file, so the cost is irrelevant next to what a cheaper
            // filter would leave in the audio a model has to recognise.
            "--src-complexity", "bats",
            "--src-quality", "127",
            source.path,
            destination.path,
        ])

        guard result.status == 0 else {
            throw Failure.Reason.converterFailed(status: result.status, message: result.message)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: destination)
        } catch {
            throw Failure.Reason.derivedFileUnreadable(error.localizedDescription)
        }
        let format = file.fileFormat
        guard Int(format.sampleRate) == sampleRate, format.channelCount == 1 else {
            throw Failure.Reason.unexpectedDerivedFormat(
                sampleRate: format.sampleRate, channelCount: format.channelCount)
        }
        return Int(file.length)
    }

    private struct ConverterResult: Sendable {
        let status: Int32
        let message: String
    }

    private static func run(_ arguments: [String]) async throws -> ConverterResult {
        let process = Process()
        process.executableURL = converter
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            throw Failure.Reason.converterUnavailable(error.localizedDescription)
        }

        // afconvert reports one short line on failure and nothing on success, so the pipe
        // cannot fill and deadlock the process it is attached to.
        let message = (try? errors.fileHandleForReading.readToEnd()).flatMap { data in
            String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ConverterResult(status: process.terminationStatus, message: message ?? "")
    }
}
