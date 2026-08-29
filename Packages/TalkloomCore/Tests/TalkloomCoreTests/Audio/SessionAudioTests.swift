import AVFoundation
import Foundation
import TalkloomCore
import Testing

@Suite("Session audio derivation")
struct SessionAudioTests {
    /// A session directory that is removed however the test ends. These tests write real
    /// audio and run the real converter, so a thrown expectation must not leave WAV files
    /// behind in the temporary directory.
    private struct Session: ~Copyable {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "SessionAudio-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        /// Writes a master of `seconds` at `sampleRate`, and returns the report describing it.
        @discardableResult
        func master(
            _ file: String,
            source: TrackSource,
            content: TrackContent,
            sampleRate: Double,
            seconds: Double,
            startOffset: TimeInterval,
            origin: UInt64
        ) throws -> TrackReport {
            let frameCount = Int(sampleRate * seconds)
            let writer = try WAVWriter(
                url: directory.appending(path: file),
                sampleRate: Int(sampleRate),
                channelCount: 1)
            // A tone rather than silence: a converter that produced an empty file would
            // otherwise be indistinguishable from one that worked.
            let samples = (0..<frameCount).map { frame in
                Int16(12_000 * sin(2 * .pi * 440 * Double(frame) / sampleRate))
            }
            try samples.withUnsafeBufferPointer(writer.append)
            try writer.finish()

            return TrackReport(
                file: file,
                source: source,
                segmentIndex: 0,
                content: content,
                sampleRate: sampleRate,
                frameCount: frameCount,
                peakAmplitude: 0.36,
                droppedSampleCount: 0,
                firstSampleHostTime: origin + HostTime.hostTicks(forSeconds: startOffset))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private static let origin = HostTime.hostTicks(forSeconds: 10_000)

    private static func manifest(_ reports: [TrackReport]) -> RecordingManifest {
        RecordingManifest(startedAt: Date(timeIntervalSince1970: 0), reports: reports)
    }

    @Test("every master holding samples becomes a 16 kHz mono file beside it")
    func derivesEveryMaster() async throws {
        let session = try Session()
        let system = try session.master(
            "system.wav", source: .systemAudio, content: .remote,
            sampleRate: 48_000, seconds: 1, startOffset: 0, origin: Self.origin)
        let microphone = try session.master(
            "microphone.wav", source: .microphone, content: .local,
            sampleRate: 44_100, seconds: 1, startOffset: 1.5, origin: Self.origin)

        let derivation = try await SessionAudio.derive(
            Self.manifest([system, microphone]), in: session.directory)

        #expect(derivation.isComplete)
        #expect(derivation.tracks.count == 2)
        for track in derivation.tracks {
            let file = try AVAudioFile(forReading: track.audioURL)
            #expect(file.fileFormat.sampleRate == Double(SessionAudio.sampleRate))
            #expect(file.fileFormat.channelCount == 1)
            #expect(Int(file.length) == track.frameCount)
            #expect(abs(track.duration - 1) < 0.005)
            #expect(
                track.audioURL.deletingLastPathComponent().lastPathComponent
                    == SessionAudio.derivedDirectoryName)
        }
        #expect(
            derivation.tracks.map(\.audioURL.lastPathComponent)
                == ["system-16k.wav", "microphone-16k.wav"])
    }

    @Test("a derived track keeps the alignment and the speaker split of its master")
    func preservesTheTimeline() async throws {
        let session = try Session()
        let system = try session.master(
            "system.wav", source: .systemAudio, content: .remote,
            sampleRate: 48_000, seconds: 0.5, startOffset: 0, origin: Self.origin)
        let microphone = try session.master(
            "microphone.wav", source: .microphone, content: .local,
            sampleRate: 48_000, seconds: 0.5, startOffset: 1.353, origin: Self.origin)

        let derivation = try await SessionAudio.derive(
            Self.manifest([system, microphone]), in: session.directory)

        let derivedSystem = try #require(derivation.tracks.first { $0.source == .systemAudio })
        let derivedMicrophone = try #require(derivation.tracks.first { $0.source == .microphone })
        #expect(derivedSystem.startOffset == 0)
        #expect(abs(try #require(derivedMicrophone.startOffset) - 1.353) < 0.001)
        #expect(derivedSystem.content == .remote)
        #expect(derivedMicrophone.content == .local)
    }

    @Test("a master that never received a sample is not converted")
    func skipsEmptyMaster() async throws {
        let session = try Session()
        let recorded = try session.master(
            "system.wav", source: .systemAudio, content: .remote,
            sampleRate: 48_000, seconds: 0.25, startOffset: 0, origin: Self.origin)
        let empty = try session.master(
            "microphone.wav", source: .microphone, content: .local,
            sampleRate: 48_000, seconds: 0, startOffset: 0, origin: Self.origin)

        let derivation = try await SessionAudio.derive(
            Self.manifest([recorded, empty]), in: session.directory)

        #expect(derivation.isComplete)
        #expect(derivation.tracks.map(\.source) == [.systemAudio])
    }

    @Test("a master missing from disk is named and the other track still derives")
    func reportsMissingMaster() async throws {
        let session = try Session()
        let system = try session.master(
            "system.wav", source: .systemAudio, content: .remote,
            sampleRate: 48_000, seconds: 0.25, startOffset: 0, origin: Self.origin)
        let absent = try session.master(
            "microphone.wav", source: .microphone, content: .local,
            sampleRate: 48_000, seconds: 0.25, startOffset: 0, origin: Self.origin)
        try FileManager.default.removeItem(at: session.directory.appending(path: "microphone.wav"))

        let derivation = try await SessionAudio.derive(
            Self.manifest([system, absent]), in: session.directory)

        #expect(derivation.tracks.map(\.source) == [.systemAudio])
        #expect(
            derivation.failures
                == [SessionAudio.Failure(master: "microphone.wav", reason: .masterMissing)])
    }

    @Test("a master the converter rejects fails alone")
    func isolatesConversionFailure() async throws {
        let session = try Session()
        let system = try session.master(
            "system.wav", source: .systemAudio, content: .remote,
            sampleRate: 48_000, seconds: 0.25, startOffset: 0, origin: Self.origin)
        let corrupt = try session.master(
            "microphone.wav", source: .microphone, content: .local,
            sampleRate: 48_000, seconds: 0.25, startOffset: 0, origin: Self.origin)
        try Data(repeating: 0x7f, count: 512)
            .write(to: session.directory.appending(path: "microphone.wav"))

        let derivation = try await SessionAudio.derive(
            Self.manifest([system, corrupt]), in: session.directory)

        #expect(derivation.tracks.map(\.source) == [.systemAudio])
        let failure = try #require(derivation.failures.first)
        #expect(derivation.failures.count == 1)
        #expect(failure.master == "microphone.wav")
        guard case .converterFailed(let status, _) = failure.reason else {
            Issue.record("expected a converter failure, got \(failure.reason)")
            return
        }
        #expect(status != 0)
    }
}
