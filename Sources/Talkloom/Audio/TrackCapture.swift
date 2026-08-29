import Foundation
import TalkloomCore

/// One logical track's sequence of producer generations, from the first sample to the
/// session's last completion.
///
/// A logical track outlives the hardware that produces it. A device change kills the process
/// tap; plugging in headphones stops the microphone's engine. Neither ends the meeting, so
/// this owns the part that survives: which generation is current, which one is retiring, what
/// the replacement inherits, and the completions the session ends up with. The hardware
/// itself is the `SegmentProducer`'s, and this type knows nothing about taps or engines.
///
/// The lifecycle deliberately lives here once. It is the same state machine for both paths,
/// and while it existed twice the two copies drifted: the same reentrancy guard was spelled
/// differently on each side, and only one of them cancelled its health watch on the way out.
actor TrackCapture<Producer: SegmentProducer> {
    private let producer: Producer

    /// The generation currently delivering samples, and what it was configured with.
    private struct LiveSegment {
        let run: CaptureRun
        let generation: Producer.Generation
        let recorder: TrackRecorder
        let options: Producer.Options
        let format: SegmentFormat
    }

    /// What a replacement generation inherits from the one that failed. Holding this between
    /// the two halves of a restart is what keeps the timeline continuous: the new master
    /// starts where the old one stopped, and the wall-clock gap between them is a measurement
    /// rather than a guess.
    private struct InterruptedPath {
        let runID: UUID
        let nextSegmentIndex: Int
        let precedingEndHostTime: UInt64?
        let options: Producer.Options
    }

    private var current: LiveSegment?
    private var interrupted: InterruptedPath?
    private var completedSegments: [TrackRecorder.Completion] = []
    private var retiringRecorder: TrackRecorder?
    private var preparingRecorder: TrackRecorder?
    private var preparingGeneration: Producer.Generation?
    private var preparingURL: URL?
    private var runtimeEventHandler: (@Sendable (CaptureRuntimeEvent) -> Void)?
    private var reportedRunIDs: Set<UUID> = []

    /// Invalidates a start that is still suspended. Every await inside `startSegment` is a
    /// point where a stop or a second start can arrive; the operation that resumes to find a
    /// different id has been overtaken and must not publish itself.
    private var operationID = UUID()
    private var replacementRunID: UUID?
    private var isFinishingSession = false
    private var finishWaiters: [CheckedContinuation<[TrackRecorder.Completion], Never>] = []

    init(producer: Producer) {
        self.producer = producer
    }

    init() {
        self.init(producer: Producer())
    }

    // No `deinit` here on purpose. Dropping this actor without stopping it must still give
    // the hardware back — an aggregate device that is never destroyed outlives the process
    // and becomes litter in the user's audio system — but a nonisolated deinit may not touch
    // actor state, and an `isolated deinit` would raise the deployment floor. The producer
    // holds its own generations for exactly that reason and tears them down in its `deinit`,
    // which runs when this actor releases it. `finishSession()` remains the ordinary path,
    // and is the only one that also flushes the files.

    /// The live generation's recorder, for the few questions only a running track can answer.
    var currentRecorder: TrackRecorder? { current?.recorder }

    /// Starts the session's first generation, and reports the format the hardware chose.
    @discardableResult
    func start(writingTo url: URL, options: Producer.Options) async throws -> SegmentFormat {
        if let current { return current.format }
        guard interrupted == nil, retiringRecorder == nil, preparingRecorder == nil else {
            throw CancellationError()
        }
        completedSegments = []
        interrupted = nil
        let segment = try await startSegment(
            writingTo: url,
            segmentIndex: 0,
            precedingEndHostTime: nil,
            options: options
        )
        return segment.format
    }

    func begin(writingTo url: URL, options: Producer.Options) async throws -> CaptureRun {
        if let current { return current.run }
        _ = try await start(writingTo: url, options: options)
        guard let current else { throw CancellationError() }
        return current.run
    }

    func observeRuntimeEvents(
        _ handler: @escaping @Sendable (CaptureRuntimeEvent) -> Void
    ) async {
        runtimeEventHandler = handler
        guard let current else { return }
        beginWatching(current)
        await observeRecorderFailure(current.recorder, runID: current.run.id)
    }

    func monitorFirstSample(_ handler: @escaping @Sendable (UInt64) -> Void) async {
        guard let current else { return }
        await current.recorder.observeFirstSample(handler)
    }

    /// Replaces the generation named by `event` with a fresh one writing to `nextSegmentURL`.
    ///
    /// Restart and reconfiguration are the same operation: retire one generation, hand its
    /// end of the timeline to the next. They differ only in whether the caller wants
    /// different options than the retiring generation had.
    func replace(
        runID: UUID,
        writingTo nextSegmentURL: URL,
        options: Producer.Options?
    ) async throws -> CaptureRestartResult {
        guard replacementRunID == nil else { return .stale }
        replacementRunID = runID
        defer {
            if replacementRunID == runID { replacementRunID = nil }
        }
        guard let context = await interrupt(runID: runID) else { return .stale }
        guard !isFinishingSession, interrupted?.runID == context.runID else { return .stale }

        let segment: LiveSegment
        do {
            segment = try await startSegment(
                writingTo: nextSegmentURL,
                segmentIndex: context.nextSegmentIndex,
                precedingEndHostTime: context.precedingEndHostTime,
                options: options ?? context.options
            )
        } catch is CancellationError {
            return .stale
        }
        guard current?.run == segment.run, !isFinishingSession else { return .stale }
        interrupted = nil
        return .restarted(segment.run)
    }

    func stop() async -> TrackRecorder.Completion? {
        await finishSession().last
    }

    /// Ends every generation this session produced and returns them in order.
    ///
    /// Concurrent callers wait for the one that got here first rather than racing it: a
    /// second teardown of the same resources is how a valid recording becomes a crash.
    func finishSession() async -> [TrackRecorder.Completion] {
        if isFinishingSession {
            return await withCheckedContinuation { finishWaiters.append($0) }
        }
        guard
            current != nil || retiringRecorder != nil || preparingRecorder != nil
                || !completedSegments.isEmpty
        else { return [] }

        isFinishingSession = true
        operationID = UUID()
        replacementRunID = nil
        runtimeEventHandler = nil
        producer.stopWatching()

        let live = current
        current = nil
        if let live {
            live.recorder.input.closeProducer()
            producer.release(
                live.generation,
                context: "stopping \(producer.descriptor.name) capture")
        }
        let retiringRecorder = self.retiringRecorder
        self.retiringRecorder = nil
        let preparingRecorder = self.preparingRecorder
        let preparingGeneration = self.preparingGeneration
        let preparingURL = self.preparingURL
        self.preparingRecorder = nil
        self.preparingGeneration = nil
        self.preparingURL = nil
        if let preparingGeneration {
            producer.release(
                preparingGeneration,
                context: "stopping \(producer.descriptor.name) preparation")
        }

        if let live { appendCompleted(await finalizedCompletion(for: live.recorder)) }
        if let retiringRecorder {
            appendCompleted(await finalizedCompletion(for: retiringRecorder))
        }
        if let preparingRecorder {
            _ = await preparingRecorder.finish()
            if let preparingURL { try? FileManager.default.removeItem(at: preparingURL) }
        }
        interrupted = nil

        let completions = completedSegments
        completedSegments = []
        reportedRunIDs = []
        isFinishingSession = false
        let waiters = finishWaiters
        finishWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(returning: completions) }
        return completions
    }

    // MARK: - One generation

    private func startSegment(
        writingTo url: URL,
        segmentIndex: Int,
        precedingEndHostTime: UInt64?,
        options: Producer.Options
    ) async throws -> LiveSegment {
        guard !isFinishingSession else { throw CancellationError() }

        // Nothing is acquired until this returns, so a throw here needs no rollback.
        let (generation, format) = try producer.acquire(options)

        let recorder: TrackRecorder
        do {
            recorder = try TrackRecorder(
                label: producer.descriptor.trackLabel,
                url: url,
                source: producer.descriptor.source,
                segmentIndex: segmentIndex,
                sampleRate: format.sampleRate,
                content: producer.content(for: options),
                precedingSegmentEndHostTime: precedingEndHostTime
            )
        } catch {
            producer.release(generation, context: "rolling back track recorder creation")
            throw error
        }

        let run = CaptureRun(id: UUID(), segmentIndex: segmentIndex)
        let operationID = UUID()
        self.operationID = operationID
        preparingRecorder = recorder
        preparingGeneration = generation
        preparingURL = url
        await recorder.start()
        guard self.operationID == operationID, !isFinishingSession,
            preparingRecorder != nil, preparingGeneration === generation
        else { throw CancellationError() }

        do {
            try producer.attach(generation, to: recorder.input)
        } catch {
            preparingGeneration = nil
            producer.release(
                generation,
                context: "rolling back a failed \(producer.descriptor.name) start")
            _ = await recorder.finish()
            guard self.operationID == operationID, !isFinishingSession else {
                throw CancellationError()
            }
            preparingRecorder = nil
            preparingURL = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        let segment = LiveSegment(
            run: run,
            generation: generation,
            recorder: recorder,
            options: options,
            format: format
        )
        preparingRecorder = nil
        preparingGeneration = nil
        preparingURL = nil
        current = segment
        if runtimeEventHandler != nil {
            beginWatching(segment)
            await observeRecorderFailure(recorder, runID: run.id)
        }
        guard self.operationID == operationID, current?.run == run, !isFinishingSession else {
            throw CancellationError()
        }

        producer.logStarted(generation, format: format)
        return segment
    }

    /// Retires the generation named by `runID` and returns what its replacement inherits.
    ///
    /// The producer stops first, then the drain waits for the callback that may already be
    /// inside `TrackInput.write` to leave. Only then is the end of the timeline readable:
    /// taking it while a write is in flight would hand the next segment an anchor that is
    /// about to move.
    private func interrupt(runID: UUID) async -> InterruptedPath? {
        if let interrupted, interrupted.runID == runID { return interrupted }
        guard !isFinishingSession, let segment = current, segment.run.id == runID else {
            return nil
        }

        producer.stopWatching()
        current = nil
        let operationID = UUID()
        self.operationID = operationID
        retiringRecorder = segment.recorder
        segment.recorder.input.closeProducer()
        producer.release(
            segment.generation,
            context: "restarting \(producer.descriptor.name) capture")
        while segment.recorder.input.hasActiveProducerWrite { await Task.yield() }
        guard self.operationID == operationID, !isFinishingSession else { return nil }
        let context = InterruptedPath(
            runID: runID,
            nextSegmentIndex: segment.run.segmentIndex + 1,
            precedingEndHostTime: segment.recorder.input.lastSampleEndHostTime,
            options: segment.options
        )
        interrupted = context
        let completion = await finalizedCompletion(for: segment.recorder)
        guard self.operationID == operationID, !isFinishingSession else { return nil }
        retiringRecorder = nil
        appendCompleted(completion)
        return context
    }

    private func finalizedCompletion(
        for recorder: TrackRecorder
    ) async -> TrackRecorder.Completion {
        let input = recorder.input
        return producer.amend(await recorder.finish(), from: input)
    }

    private func appendCompleted(_ completion: TrackRecorder.Completion) {
        guard !completedSegments.contains(where: { $0.summary.url == completion.summary.url })
        else { return }
        completedSegments.append(completion)
        producer.logCompleted(completion.summary)
    }

    // MARK: - Failures

    private func beginWatching(_ segment: LiveSegment) {
        let runID = segment.run.id
        producer.beginWatching(segment.generation, input: segment.recorder.input) {
            [weak self] message, retryability in
            Task { [weak self] in
                await self?.reportRuntimeEvent(
                    runID: runID,
                    message: message,
                    retryability: retryability)
            }
        }
    }

    private func observeRecorderFailure(_ recorder: TrackRecorder, runID: UUID) async {
        await recorder.observeFailures { [weak self] failure in
            Task {
                await self?.reportRuntimeEvent(
                    runID: runID,
                    message: failure.localizedDescription,
                    retryability: .terminal
                )
            }
        }
    }

    /// Reports a generation's failure once, and only while it is still the current one.
    ///
    /// A generation that has already been replaced has nothing left to say: acting on its
    /// report would restart the healthy generation that took its place.
    private func reportRuntimeEvent(
        runID: UUID,
        message: String,
        retryability: CaptureRuntimeEvent.Retryability
    ) {
        guard current?.run.id == runID, let runtimeEventHandler,
            reportedRunIDs.insert(runID).inserted
        else { return }
        AppLog.capture.error("\(message, privacy: .public)")
        producer.stopWatching()
        runtimeEventHandler(
            CaptureRuntimeEvent(runID: runID, message: message, retryability: retryability))
    }
}
