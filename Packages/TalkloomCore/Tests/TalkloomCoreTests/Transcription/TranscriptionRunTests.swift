import Foundation
import Synchronization
import TalkloomCore
import Testing

@Suite("Transcription run")
struct TranscriptionRunTests {
    /// A clock that records what it was asked to wait for and never actually waits, so backoff
    /// is asserted as a value instead of paid for as test duration.
    ///
    /// `now` is frozen at construction. A clock that never sleeps must not advance either, or
    /// the requested duration comes back shortened by however long the test itself took.
    private final class RecordingClock: Clock, Sendable {
        typealias Instant = ContinuousClock.Instant

        private let origin = ContinuousClock().now
        private let waits = Mutex<[Duration]>([])

        var now: Instant { origin }
        var minimumResolution: Duration { .zero }

        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            waits.withLock { $0.append(deadline - origin) }
        }

        var recordedWaits: [Duration] { waits.withLock { $0 } }
    }

    private actor ScriptedTranscriber: Transcriber {
        private var outcomes: [String: [Result<TranscriptionResult, any Error>]]
        private(set) var calls: [String] = []

        init(outcomes: [String: [Result<TranscriptionResult, any Error>]]) {
            self.outcomes = outcomes
        }

        func transcribe(_ chunk: TranscriptionChunk) async throws -> TranscriptionResult {
            let name = chunk.audioURL.lastPathComponent
            calls.append(name)
            guard var remaining = outcomes[name], !remaining.isEmpty else {
                throw TestFailure.unscripted(name)
            }
            let outcome = remaining.removeFirst()
            // The last scripted outcome repeats, so "always fails" needs no attempt count here.
            if !remaining.isEmpty { outcomes[name] = remaining }
            return try outcome.get()
        }

        func callCount(for name: String) -> Int { calls.filter { $0 == name }.count }
    }

    private enum TestFailure: Error, Equatable {
        case unscripted(String)
        case unclassified
    }

    private static func chunk(
        _ name: String,
        startOffset: TimeInterval = 0,
        duration: TimeInterval = 10,
        source: TrackSource = .microphone
    ) -> TranscriptionChunk {
        TranscriptionChunk(
            audioURL: URL(filePath: "/tmp/\(name).wav"),
            startOffset: startOffset,
            duration: duration,
            source: source)
    }

    private static func result(
        _ text: String,
        startTime: TimeInterval,
        source: TrackSource = .microphone
    ) -> TranscriptionResult {
        TranscriptionResult(
            model: "test",
            segments: [
                TranscriptSegment(
                    startTime: startTime,
                    endTime: startTime + 1,
                    text: text,
                    language: .english,
                    source: source)
            ])
    }

    private static func policy(
        attempts: Int = 3,
        backoff: Duration = .milliseconds(10)
    ) throws -> TranscriptionRetryPolicy {
        try #require(
            TranscriptionRetryPolicy(
                maximumAttempts: attempts, initialBackoff: backoff, backoffMultiplier: 2))
    }

    @Test("a transient failure is retried until the identical request succeeds")
    func retriesTransientFailure() async throws {
        let chunk = Self.chunk("mic")
        let transcriber = ScriptedTranscriber(outcomes: [
            "mic.wav": [
                .failure(OpenRouterGeminiTranscriber.TranscriptionError.invalidResponse),
                .success(Self.result("hello", startTime: 0)),
            ]
        ])
        let clock = RecordingClock()
        let runner = TranscriptionRunner(
            transcriber: transcriber, policy: try Self.policy(), clock: clock)

        let run = try await runner.run([chunk])

        #expect(run.isComplete)
        #expect(run.successes.count == 1)
        #expect(run.successes.first?.attempts == 2)
        #expect(run.segments.map(\.text) == ["hello"])
        await #expect(transcriber.callCount(for: "mic.wav") == 2)
        #expect(clock.recordedWaits == [.milliseconds(10)])
    }

    @Test("attempts are bounded and the exhausted chunk fails explicitly")
    func exhaustsAttempts() async throws {
        let chunk = Self.chunk("mic")
        let failure = OpenRouterGeminiTranscriber.TranscriptionError.transportFailed("timed out")
        let transcriber = ScriptedTranscriber(outcomes: ["mic.wav": [.failure(failure)]])
        let clock = RecordingClock()
        let runner = TranscriptionRunner(
            transcriber: transcriber, policy: try Self.policy(), clock: clock)

        let run = try await runner.run([chunk])

        #expect(!run.isComplete)
        #expect(run.successes.isEmpty)
        let reported = try #require(run.failures.first)
        #expect(run.failures.count == 1)
        #expect(reported.chunk == chunk)
        #expect(reported.attempts == 3)
        #expect(
            reported.error as? OpenRouterGeminiTranscriber.TranscriptionError == failure)
        await #expect(transcriber.callCount(for: "mic.wav") == 3)
        #expect(clock.recordedWaits == [.milliseconds(10), .milliseconds(20)])
    }

    @Test("a permanent failure is not paid for twice")
    func doesNotRetryPermanentFailure() async throws {
        let transcriber = ScriptedTranscriber(outcomes: [
            "mic.wav": [.failure(OpenRouterGeminiTranscriber.TranscriptionError.emptyAudioFile)]
        ])
        let clock = RecordingClock()
        let runner = TranscriptionRunner(
            transcriber: transcriber, policy: try Self.policy(), clock: clock)

        let run = try await runner.run([Self.chunk("mic")])

        #expect(run.failures.first?.attempts == 1)
        await #expect(transcriber.callCount(for: "mic.wav") == 1)
        #expect(clock.recordedWaits.isEmpty)
    }

    @Test("an engine that does not classify its failure still gets the bounded retry")
    func retriesUnclassifiedFailure() async throws {
        let transcriber = ScriptedTranscriber(outcomes: [
            "mic.wav": [.failure(TestFailure.unclassified)]
        ])
        let runner = TranscriptionRunner(
            transcriber: transcriber, policy: try Self.policy(), clock: RecordingClock())

        let run = try await runner.run([Self.chunk("mic")])

        #expect(run.failures.first?.attempts == 3)
        #expect(run.failures.first?.error as? TestFailure == .unclassified)
    }

    @Test("one exhausted chunk does not discard the chunks that succeeded")
    func isolatesFailureFromOtherChunks() async throws {
        let system = Self.chunk("system", startOffset: 0, source: .systemAudio)
        let broken = Self.chunk("mic-1", startOffset: 1.5)
        let mic = Self.chunk("mic-2", startOffset: 12)
        let transcriber = ScriptedTranscriber(outcomes: [
            "system.wav": [.success(Self.result("theirs", startTime: 0.5, source: .systemAudio))],
            "mic-1.wav": [
                .failure(OpenRouterGeminiTranscriber.TranscriptionError.invalidResponse)
            ],
            "mic-2.wav": [.success(Self.result("mine", startTime: 12.5))],
        ])
        let runner = TranscriptionRunner(
            transcriber: transcriber, policy: try Self.policy(), clock: RecordingClock())

        let run = try await runner.run([system, broken, mic])

        #expect(run.successes.count == 2)
        #expect(run.failures.map(\.chunk) == [broken])
        #expect(run.segments.map(\.text) == ["theirs", "mine"])
        #expect(run.segments.map(\.source) == [.systemAudio, .microphone])
        await #expect(transcriber.callCount(for: "mic-2.wav") == 1)
    }

    @Test("cancellation ends the run instead of being recorded as a chunk failure")
    func propagatesCancellation() async throws {
        let transcriber = ScriptedTranscriber(outcomes: [
            "mic.wav": [.failure(CancellationError())]
        ])
        let runner = TranscriptionRunner(
            transcriber: transcriber, policy: try Self.policy(), clock: RecordingClock())

        await #expect(throws: CancellationError.self) {
            _ = try await runner.run([Self.chunk("mic")])
        }
    }

    @Test("the segments of one run are ordered on the meeting timeline")
    func ordersSegmentsAcrossTracks() throws {
        let run = TranscriptionRun(
            successes: [
                TranscriptionRun.ChunkSuccess(
                    chunk: Self.chunk("mic"),
                    attempts: 1,
                    result: TranscriptionResult(
                        model: "test",
                        segments: [
                            TranscriptSegment(
                                startTime: 4, endTime: 5, text: "second", language: .english,
                                source: .microphone)
                        ])),
                TranscriptionRun.ChunkSuccess(
                    chunk: Self.chunk("system", source: .systemAudio),
                    attempts: 1,
                    result: TranscriptionResult(
                        model: "test",
                        segments: [
                            TranscriptSegment(
                                startTime: 1, endTime: 2, text: "first", language: .russian,
                                source: .systemAudio),
                            TranscriptSegment(
                                startTime: 4, endTime: 6, text: "third", language: .russian,
                                source: .systemAudio),
                        ])),
            ],
            failures: [])

        #expect(run.segments.map(\.text) == ["first", "second", "third"])
    }

    @Test(
        "a policy needs at least one attempt and a backoff that does not shrink",
        arguments: [
            (0, Duration.milliseconds(1), 2),
            (-1, Duration.milliseconds(1), 2),
            (3, Duration.milliseconds(-1), 2),
            (3, Duration.milliseconds(1), 0),
        ])
    func rejectsUnusablePolicy(attempts: Int, backoff: Duration, multiplier: Int) {
        #expect(
            TranscriptionRetryPolicy(
                maximumAttempts: attempts, initialBackoff: backoff, backoffMultiplier: multiplier)
                == nil)
    }

    @Test(
        "the client classifies which of its failures a retry could fix",
        arguments: [
            (OpenRouterGeminiTranscriber.TranscriptionError.transportFailed("reset"), true),
            (.invalidHTTPResponse, true),
            (.invalidResponse, true),
            (.httpFailure(statusCode: 429, message: "rate limited"), true),
            (.httpFailure(statusCode: 500, message: "server error"), true),
            (.httpFailure(statusCode: 408, message: "request timeout"), true),
            (.httpFailure(statusCode: 401, message: "no credentials"), false),
            (.httpFailure(statusCode: 400, message: "bad request"), false),
            (.invalidAudioURL, false),
            (.unsupportedAudioFormat, false),
            (.emptyAudioFile, false),
            (.audioFileTooLarge(actualBytes: 2, maximumBytes: 1), false),
            (.invalidChunkOffset, false),
            (.invalidChunkDuration, false),
            (.audioReadFailed("no such file"), false),
            (.requestEncodingFailed, false),
        ])
    func classifiesProviderFailures(
        error: OpenRouterGeminiTranscriber.TranscriptionError,
        isTransient: Bool
    ) {
        #expect(error.isTransient == isTransient)
    }
}
