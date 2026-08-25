import AVFoundation
import Foundation
import TranscriberCore

/// One recorded track, end to end: the handle an audio callback writes into, and the
/// consumer that drains it and writes the file.
///
/// The consumer does as little as possible: it writes the device's own sample rate straight
/// to disk. Producing the 16 kHz mono copy ASR wants happens once, afterwards, over the
/// finished file (`afconvert`, see `PLAN.md` stage 2). Nothing here has to keep up with
/// anything — this project transcribes after the meeting, so the recording is the master
/// and accuracy beats immediacy.
///
/// Resampling on the audio path was measurably worse, not just more code. A resampler is a
/// polyphase FIR holding some 30 input frames in its delay line, and it only gives them
/// back when the stream is declared finished. A drain loop can never declare that — more
/// audio is always coming — so every pass abandons the filter's contents, and every pass
/// that hands the converter more input than one call consumes loses the remainder outright.
/// Measured on a one-second 48 kHz tone: 6% of the recording gone. Over a finished file,
/// with a real end of stream, the same conversion is frame-exact.
actor TrackRecorder {
    /// Seconds the producer may run unattended before the ring buffer overflows. Far more
    /// than the drain interval needs, and about a megabyte at 48 kHz.
    private static let ringHeadroom = 4.0

    /// Samples moved from the ring to disk per pass.
    private static let drainChunkFrames = 8_192

    private static let drainInterval = Duration.milliseconds(50)

    /// What a finished track amounts to. `peakAmplitude` is the number that decides whether
    /// a recording is real: a valid file of the right duration containing pure silence is
    /// this project's signature failure, and only a peak measurement tells the two apart.
    struct Summary: Sendable {
        let label: String
        let url: URL

        /// Who is on this track. Decided by the capture path that created the recorder,
        /// since it is the only place that knows whether echo cancellation was applied.
        let content: TrackContent

        let sampleRate: Double
        let frameCount: Int
        let peakAmplitude: Float
        let droppedSampleCount: Int

        /// Mach host time represented by frame zero of the master. Tracks are merged against
        /// each other on this, not on the moment the user pressed record.
        let firstSampleHostTime: UInt64?

        /// Real-sample runs around any native-rate silence inserted for dropped blocks.
        /// `nil` means at least one callback block lacked the hardware anchor needed to
        /// describe the timeline truthfully.
        let spans: [TrackReport.Span]?

        var duration: TimeInterval { Double(frameCount) / sampleRate }
        var isSilent: Bool { peakAmplitude < 0.001 }

        /// The device delivered samples outside `[-1, 1]`. Float32 audio is not clamped by
        /// the hardware, so an input gain set too high arrives intact and is only truncated
        /// when it reaches Int16 — measured at 2.03 with a microphone next to loud
        /// speakers. The result is a distorted recording, which ASR handles badly, so it is
        /// worth saying out loud rather than leaving to be noticed by ear.
        var isClipped: Bool { peakAmplitude > 1 }

        /// Within a decibel of full scale. Not clipped yet, and one loud sentence away from
        /// it — measured at -0.6 dBFS on a normal speaking voice, which the clipping check
        /// above passes silently.
        var isTooLoud: Bool { peakAmplitude >= 0.891 }
    }

    struct Completion: Sendable {
        let summary: Summary
        let failure: Failure?
    }

    let label: String
    let url: URL
    let content: TrackContent
    let sampleRate: Double

    /// The producer's handle. `nonisolated` because an audio callback cannot await.
    nonisolated let input: TrackInput

    private let writer: any PCMWriting
    private var floatScratch: [Float]
    private var intScratch: [Int16]
    private var silenceScratch: [Int16]
    private var peak: Float = 0
    private var drainTask: Task<Void, Never>?
    private var isFinished = false
    private var firstFailure: Failure?
    private var failureHandler: (@Sendable (Failure) -> Void)?
    private var firstSampleHandler: (@Sendable (UInt64) -> Void)?
    private var didReportFirstSample = false
    private var nextSignalObservationID: UInt64 = 0
    private var signalObservation: SignalObservationState?
    private var sourceFramesRead = 0
    private var nextBoundary: TimelineBoundary?
    private var openSpan: OpenSpan?
    private var completedSpans: [TrackReport.Span] = []

    private struct OpenSpan {
        let sourceFrameOffset: Int
        let fileFrameOffset: Int
        let startHostTime: UInt64
    }

    struct SignalObservation: Sendable, Equatable {
        fileprivate let id: UInt64
    }

    private struct SignalObservationState {
        let token: SignalObservation
        let threshold: Float
        var didObserve = false
    }

    enum Failure: Error, LocalizedError, Sendable, Equatable {
        case unsupportedSourceFormat(sampleRate: Double)
        case writeFailed(label: String, reason: String)
        case finalizationFailed(label: String, reason: String)
        case unexpectedBufferLayout(label: String, blockCount: Int)
        case invalidTimeline(label: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSourceFormat(let sampleRate):
                "The audio source reported an unusable sample rate (\(sampleRate) Hz)."
            case .writeFailed(let label, let reason):
                "The \(label) track could not write audio: \(reason)"
            case .finalizationFailed(let label, let reason):
                "The \(label) track could not finalize its WAV header: \(reason)"
            case .unexpectedBufferLayout(let label, let blockCount):
                "The \(label) track received \(blockCount) unsupported audio block(s)."
            case .invalidTimeline(let label, let reason):
                "The \(label) track could not preserve its timeline: \(reason)"
            }
        }
    }

    /// - Parameter sampleRate: the rate the callback actually delivers, read from the device
    ///   rather than assumed. Assuming it is the mistake that yields a file of the right
    ///   length playing back at the wrong speed.
    init(
        label: String,
        url: URL,
        sampleRate: Double,
        content: TrackContent,
        writer suppliedWriter: (any PCMWriting)? = nil
    ) throws {
        guard sampleRate > 0 else { throw Failure.unsupportedSourceFormat(sampleRate: sampleRate) }

        self.label = label
        self.url = url
        self.content = content
        self.sampleRate = sampleRate
        self.input = TrackInput(ringCapacity: Int(sampleRate * Self.ringHeadroom))
        self.floatScratch = [Float](repeating: 0, count: Self.drainChunkFrames)
        self.intScratch = [Int16](repeating: 0, count: Self.drainChunkFrames)
        self.silenceScratch = [Int16](repeating: 0, count: Self.drainChunkFrames)
        // Int16 at the device's rate, not Float32: it is the format every downstream tool
        // reads without argument, and 16 bits is some 90 dB of headroom below anything a
        // meeting recording resolves.
        self.writer =
            try suppliedWriter
            ?? WAVWriter(url: url, sampleRate: Int(sampleRate.rounded()), channelCount: 1)
    }

    /// Starts draining. Safe to call before the producer has delivered anything.
    func start() {
        guard drainTask == nil, !isFinished else { return }
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.drainInterval)
                await self?.drain()
            }
        }
    }

    /// Reports the first failure the drain observes, instead of keeping it until `finish()`.
    ///
    /// Everything this actor can fail at happens while the meeting is still being recorded,
    /// and the drain is the only part that sees it: after a failure it stops writing, the
    /// producer goes on filling the ring, and the file stops growing behind a UI that still
    /// says "recording". Whoever owns the session hears about it here and can stop.
    ///
    /// A failure that already happened is delivered on subscription, because the drain
    /// starts as soon as capture does — before the session is ready to be told about one.
    func observeFailures(_ handler: @escaping @Sendable (Failure) -> Void) {
        // A closed track has nothing left to report: its completion already carries the
        // failure, and holding the handler would only keep the subscriber alive.
        guard !isFinished else { return }
        failureHandler = handler
        if let firstFailure { deliver(firstFailure) }
    }

    /// Reports the first hardware timestamp from outside the real-time callback.
    ///
    /// The callback only stores one atomic value. The drain actor notices it here and hands
    /// it to the session owner, which may safely checkpoint `session.json` on disk. A sample
    /// that arrived before observation was armed is delivered immediately.
    func observeFirstSample(_ handler: @escaping @Sendable (UInt64) -> Void) {
        guard !isFinished else { return }
        firstSampleHandler = handler
        reportFirstSampleIfNeeded()
    }

    /// Discards the already-buffered past and arms a new signal observation epoch.
    func beginSignalObservation(above threshold: Float) -> SignalObservation {
        drain()
        nextSignalObservationID &+= 1
        let token = SignalObservation(id: nextSignalObservationID)
        signalObservation = SignalObservationState(token: token, threshold: threshold)
        return token
    }

    /// Waits for the drain to observe a new sample above the armed verification level.
    ///
    /// This runs on the recorder actor, after the real-time callback has copied samples into
    /// the ring. It is used for an active system-audio probe, not to infer that an arbitrary
    /// quiet recording lacks permission.
    func waitForSignal(_ token: SignalObservation, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !isFinished, isSignalObservationPending(token), clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                break
            }
        }
        let didObserve = signalObservation?.token == token && signalObservation?.didObserve == true
        cancelSignalObservation(token)
        return didObserve
    }

    func cancelSignalObservation(_ token: SignalObservation) {
        guard signalObservation?.token == token else { return }
        signalObservation = nil
    }

    /// Stops draining, flushes whatever the producer left behind, and closes the file.
    ///
    /// The caller must have stopped the producer first: anything written after this point
    /// stays in the ring buffer and never reaches disk.
    func finish() async -> Completion {
        if let drainTask {
            drainTask.cancel()
            await drainTask.value
        }
        drainTask = nil

        if firstFailure == nil {
            drain()
            let terminalDrop = input.terminalDroppedFrameCount()
            if terminalDrop > 0 { _ = appendSilence(frameCount: terminalDrop) }
            closeOpenSpan(atSourceFrameOffset: sourceFramesRead)
        }
        isFinished = true
        // Nobody is listening once the track is closed; the completion carries the failure.
        failureHandler = nil
        firstSampleHandler = nil
        do {
            try writer.finish()
        } catch {
            recordFailure(
                .finalizationFailed(label: label, reason: error.localizedDescription)
            )
        }

        return Completion(
            summary: Summary(
                label: label,
                url: url,
                content: content,
                sampleRate: sampleRate,
                frameCount: writer.frameCount,
                peakAmplitude: peak,
                droppedSampleCount: input.droppedSampleCount,
                firstSampleHostTime: input.firstSampleHostTime,
                spans: input.hasCompleteTimeline ? completedSpans : nil
            ),
            failure: firstFailure
        )
    }

    private func drain() {
        guard !isFinished else { return }
        reportFirstSampleIfNeeded()
        guard firstFailure == nil else { return }
        let capacity = floatScratch.count

        while true {
            // Acquire the audio cursor before the boundary cursor. The producer publishes in
            // the opposite order, so seeing post-boundary audio guarantees the matching
            // boundary is visible before this read chooses how many frames it may cross.
            let available = input.ring.availableToRead
            if nextBoundary == nil { nextBoundary = input.readBoundary() }
            if let boundary = nextBoundary,
                boundary.sourceFrameOffset == sourceFramesRead
            {
                guard beginSpan(at: boundary) else { return }
                nextBoundary = input.readBoundary()
                continue
            }
            if let boundary = nextBoundary, boundary.sourceFrameOffset < sourceFramesRead {
                recordFailure(
                    .invalidTimeline(
                        label: label,
                        reason: "a span boundary regressed behind written audio"
                    ))
                return
            }

            let untilBoundary = nextBoundary.map {
                max(0, $0.sourceFrameOffset - sourceFramesRead)
            }
            let requested = min(capacity, min(available, untilBoundary ?? capacity))
            guard requested > 0 else { return }

            let read = floatScratch.withUnsafeMutableBufferPointer {
                input.ring.read(into: $0.baseAddress!, count: requested)
            }
            guard read > 0 else { return }

            var chunkPeak: Float = 0
            for index in 0..<read {
                let sample = floatScratch[index]
                chunkPeak = max(chunkPeak, abs(sample))
                intScratch[index] = Self.int16(from: sample)
            }

            do {
                try intScratch.withUnsafeBufferPointer {
                    try writer.append(UnsafeBufferPointer(start: $0.baseAddress!, count: read))
                }
            } catch {
                recordFailure(
                    .writeFailed(label: label, reason: error.localizedDescription)
                )
                return
            }
            peak = max(peak, chunkPeak)
            sourceFramesRead += read
            if var observation = signalObservation, chunkPeak >= observation.threshold {
                observation.didObserve = true
                signalObservation = observation
            }

            // A short read means the ring is empty; the rest arrives on the next pass.
            if read < requested { return }
        }
    }

    private func beginSpan(at boundary: TimelineBoundary) -> Bool {
        closeOpenSpan(atSourceFrameOffset: boundary.sourceFrameOffset)
        guard appendSilence(frameCount: boundary.silentFrameCount) else { return false }
        openSpan = OpenSpan(
            sourceFrameOffset: boundary.sourceFrameOffset,
            fileFrameOffset: writer.frameCount,
            startHostTime: boundary.startHostTime
        )
        return true
    }

    private func closeOpenSpan(atSourceFrameOffset end: Int) {
        guard let openSpan else { return }
        let frameCount = end - openSpan.sourceFrameOffset
        if frameCount > 0 {
            completedSpans.append(
                TrackReport.Span(
                    fileFrameOffset: openSpan.fileFrameOffset,
                    frameCount: frameCount,
                    startHostTime: openSpan.startHostTime
                ))
        }
        self.openSpan = nil
    }

    @discardableResult
    private func appendSilence(frameCount: Int) -> Bool {
        var remaining = frameCount
        while remaining > 0 {
            let count = min(remaining, silenceScratch.count)
            do {
                try silenceScratch.withUnsafeBufferPointer {
                    try writer.append(UnsafeBufferPointer(start: $0.baseAddress!, count: count))
                }
            } catch {
                recordFailure(.writeFailed(label: label, reason: error.localizedDescription))
                return false
            }
            remaining -= count
        }
        return true
    }

    private func reportFirstSampleIfNeeded() {
        guard !didReportFirstSample, let hostTime = input.firstSampleHostTime,
            let firstSampleHandler
        else { return }
        didReportFirstSample = true
        self.firstSampleHandler = nil
        firstSampleHandler(hostTime)
    }

    private func isSignalObservationPending(_ token: SignalObservation) -> Bool {
        signalObservation?.token == token && signalObservation?.didObserve == false
    }

    private func recordFailure(_ failure: Failure) {
        guard firstFailure == nil else { return }
        firstFailure = failure
        AppLog.capture.error("\(failure.localizedDescription, privacy: .public)")
        deliver(failure)
    }

    /// Hands the failure to the observer exactly once. Whoever hears it stops the session,
    /// so a second report would arrive at a session that is already stopping.
    private func deliver(_ failure: Failure) {
        let handler = failureHandler
        failureHandler = nil
        handler?(failure)
    }

    /// Float32 in `[-1, 1]` to Int16.
    ///
    /// Scaled by 32767 rather than 32768 so a full-scale sample cannot wrap round to the
    /// most negative value, which is heard as a click exactly where the audio was loudest.
    private static func int16(from sample: Float) -> Int16 {
        Int16((min(max(sample, -1), 1) * 32_767).rounded())
    }
}
