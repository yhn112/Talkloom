import Foundation

/// An engine's own judgement about whether repeating an identical request could succeed.
///
/// Retry policy cannot be read off an error's text, and the runner is engine-agnostic, so
/// each engine classifies its own failures. An error that does not classify itself is
/// treated as transient: repeating it costs at most the policy's attempt budget, while
/// calling an unrecognised failure permanent silently drops a finished piece of the meeting.
public protocol ClassifiedTranscriptionError: Error {
    var isTransient: Bool { get }
}

/// How many times one chunk may be sent before its failure becomes the run's answer for it.
///
/// The bound is what makes a provider that fails identically forever terminate at a cost the
/// user can predict, rather than spending the meeting's audio against a broken route.
public struct TranscriptionRetryPolicy: Equatable, Sendable {
    public let maximumAttempts: Int
    public let initialBackoff: Duration
    public let backoffMultiplier: Int

    /// Three attempts, because the reproduced provider failure in `Tests/reports/baseline.md`
    /// succeeded on an identical immediate repeat: the case this defends against is one bad
    /// structured-output sample, not a sustained outage.
    public static let `default` = TranscriptionRetryPolicy(
        attempts: 3, backoff: .milliseconds(500), multiplier: 2)

    public init?(maximumAttempts: Int, initialBackoff: Duration, backoffMultiplier: Int) {
        guard maximumAttempts >= 1, initialBackoff >= .zero, backoffMultiplier >= 1 else {
            return nil
        }
        self.init(
            attempts: maximumAttempts, backoff: initialBackoff, multiplier: backoffMultiplier)
    }

    private init(attempts: Int, backoff: Duration, multiplier: Int) {
        maximumAttempts = attempts
        initialBackoff = backoff
        backoffMultiplier = multiplier
    }

    /// The wait before `attempt`, which is 2 for the first retry.
    func backoff(before attempt: Int) -> Duration {
        guard attempt > 1 else { return .zero }
        var delay = initialBackoff
        for _ in 0..<(attempt - 2) { delay *= backoffMultiplier }
        return delay
    }
}

/// What one pass over a session's speech chunks produced, successes and failures side by side.
///
/// A failed chunk is a named hole in the transcript, never a reason to discard the chunks
/// that did succeed: the masters stay intact and every other chunk was paid for already.
public struct TranscriptionRun: Sendable {
    public struct ChunkSuccess: Sendable {
        public let chunk: TranscriptionChunk
        public let attempts: Int
        public let result: TranscriptionResult

        public init(chunk: TranscriptionChunk, attempts: Int, result: TranscriptionResult) {
            self.chunk = chunk
            self.attempts = attempts
            self.result = result
        }
    }

    public struct ChunkFailure: Sendable {
        public let chunk: TranscriptionChunk
        public let attempts: Int
        public let error: any Error

        public init(chunk: TranscriptionChunk, attempts: Int, error: any Error) {
            self.chunk = chunk
            self.attempts = attempts
            self.error = error
        }
    }

    public let successes: [ChunkSuccess]
    public let failures: [ChunkFailure]

    public init(successes: [ChunkSuccess], failures: [ChunkFailure]) {
        self.successes = successes
        self.failures = failures
    }

    public var isComplete: Bool { failures.isEmpty }

    /// Every recognised segment on the meeting timeline, ordered. Chunk offsets are already
    /// absolute, so this interleaves the microphone and system tracks; each segment keeps the
    /// `source` that is the project's first-level speaker split.
    public var segments: [TranscriptSegment] {
        successes
            .flatMap(\.result.segments)
            .sorted {
                if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                if $0.endTime != $1.endTime { return $0.endTime < $1.endTime }
                return $0.source.rawValue < $1.source.rawValue
            }
    }
}

/// Sends a session's finished speech chunks through one ASR engine, retrying a transient
/// failure within the policy's bound and isolating a chunk that stays broken.
///
/// Chunks are sent one at a time. Nothing here is live, provider concurrency is rate limited,
/// and a sequential run keeps the failure of one chunk from being entangled with another's;
/// parallelism is a speed decision for the chunking layer to make with a measurement behind it.
public struct TranscriptionRunner: Sendable {
    private let transcriber: any Transcriber
    private let policy: TranscriptionRetryPolicy
    private let clock: any Clock<Duration>

    public init(
        transcriber: any Transcriber,
        policy: TranscriptionRetryPolicy = .default,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.transcriber = transcriber
        self.policy = policy
        self.clock = clock
    }

    /// Throws only on cancellation; a provider failure is reported in the returned run.
    public func run(_ chunks: [TranscriptionChunk]) async throws -> TranscriptionRun {
        var successes: [TranscriptionRun.ChunkSuccess] = []
        var failures: [TranscriptionRun.ChunkFailure] = []

        for chunk in chunks {
            try Task.checkCancellation()
            var attempt = 1
            attempts: while true {
                do {
                    let result = try await transcriber.transcribe(chunk)
                    successes.append(
                        TranscriptionRun.ChunkSuccess(
                            chunk: chunk, attempts: attempt, result: result))
                    break attempts
                } catch {
                    // A cancelled transport reports its own error type, so the task's state
                    // decides this rather than the shape of what the engine threw.
                    if Task.isCancelled { throw CancellationError() }
                    if error is CancellationError { throw error }

                    let isTransient =
                        (error as? any ClassifiedTranscriptionError)?.isTransient ?? true
                    guard isTransient, attempt < policy.maximumAttempts else {
                        failures.append(
                            TranscriptionRun.ChunkFailure(
                                chunk: chunk, attempts: attempt, error: error))
                        break attempts
                    }
                    try await clock.sleep(for: policy.backoff(before: attempt + 1))
                    attempt += 1
                }
            }
        }

        return TranscriptionRun(successes: successes, failures: failures)
    }
}
