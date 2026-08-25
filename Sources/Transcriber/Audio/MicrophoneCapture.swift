import AVFoundation
import Foundation

/// Two stable engine graphs for the two microphone modes.
///
/// AVFAudio delivers Voice Processing IO property notifications on an internal queue and
/// provides no teardown-completion API. A segment therefore borrows one of these engines;
/// destroying the segment must not destroy the engine while a property listener may still
/// be running. `MicrophoneCapture` is process-long-lived and retains this set across every
/// segment and session.
final class MicrophoneEngineSet {
    private let voiceProcessingEngine = AVAudioEngine()
    private let rawEngine = AVAudioEngine()

    func engine(voiceProcessing: Bool) -> AVAudioEngine {
        voiceProcessing ? voiceProcessingEngine : rawEngine
    }
}

/// Records the microphone through Voice Processing IO.
///
/// Echo cancellation is not a refinement here, it is the reason this path exists. Without
/// it the microphone picks up the other participants coming back out of the speakers,
/// Whisper transcribes them from the microphone track too, and every remote line lands in
/// the transcript twice — the second time attributed to "me". Headphones would solve it;
/// the app cannot assume them.
actor MicrophoneCapture: MicrophoneCapturing {
    /// Frames requested per tap callback. The node is free to deliver a different size, so
    /// nothing downstream may assume it.
    private static let tapBufferSize: AVAudioFrameCount = 4_096

    private let engines = MicrophoneEngineSet()
    private var didEnableVoiceProcessing = false

    /// The ducking configuration that leaves the meeting as audible as voice processing
    /// allows — which is not "unducked".
    ///
    /// Voice processing ducks "other audio" so a voice chat stays intelligible. Here the
    /// other audio *is* the meeting, and the process tap records it, so ducking quiets the
    /// remote participants in the very track meant to carry them. Measured against a
    /// steady tone, the eight available configurations span 8 to 50 dB of attenuation, and
    /// this one is the floor. Apple's own sample pairs `.min` with advanced ducking turned
    /// on; that is right for a call where other audio is a distraction and costs 8 dB more
    /// here. See `DuckingMeasurementTests` for the table.
    static let transparentDucking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
        enableAdvancedDucking: false,
        duckingLevel: .min
    )

    enum Failure: Error, LocalizedError {
        case voiceProcessingUnavailable(String)
        case unusableInputFormat(sampleRate: Double, channelCount: UInt32)
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .voiceProcessingUnavailable(let reason):
                "Could not enable echo cancellation on the microphone: \(reason)"
            case .unusableInputFormat(let sampleRate, let channelCount):
                "The microphone reported an unusable format (\(sampleRate) Hz, \(channelCount) channels). Check that an input device is selected in System Settings › Sound."
            case .engineFailed(let reason):
                "Could not start the microphone: \(reason)"
            }
        }
    }

    private struct LiveSegment {
        let run: CaptureRun
        let engine: AVAudioEngine
        let recorder: TrackRecorder
        let format: AVAudioFormat
        let voiceProcessing: Bool
    }

    private struct InterruptedPath {
        let runID: UUID
        let nextSegmentIndex: Int
        let precedingEndHostTime: UInt64?
        let voiceProcessing: Bool
    }

    private var current: LiveSegment?
    private var interrupted: InterruptedPath?
    private var completedSegments: [TrackRecorder.Completion] = []
    private var retiringRecorder: TrackRecorder?
    private var preparingRecorder: TrackRecorder?
    private var preparingEngine: AVAudioEngine?
    private var preparingURL: URL?
    private var configurationObserver: (any NSObjectProtocol)?
    private var runtimeEventHandler: (@Sendable (CaptureRuntimeEvent) -> Void)?
    private var reportedRunIDs: Set<UUID> = []
    private var operationID = UUID()
    private var replacementRunID: UUID?
    private var isFinishingSession = false
    private var finishWaiters: [CheckedContinuation<[TrackRecorder.Completion], Never>] = []

    /// Starts capture into `url` and returns the format the device actually delivered.
    ///
    /// - Parameter voiceProcessing: echo cancellation.
    ///
    ///   Turning it off is not merely a diagnostic. Cancellation removes the other
    ///   participants from the microphone track, and that is only safe while the process tap
    ///   is recording them separately — the two subsystems know nothing about each other, so
    ///   nothing guarantees that what is subtracted here survives anywhere else. When the tap
    ///   is not running, this must be off, or the meeting's other half is erased from the
    ///   only recording that exists.
    @discardableResult
    func start(
        writingTo url: URL,
        voiceProcessing: Bool = true,
        ducking: AVAudioVoiceProcessingOtherAudioDuckingConfiguration = MicrophoneCapture
            .transparentDucking
    ) async throws -> AVAudioFormat {
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
            voiceProcessing: voiceProcessing,
            ducking: ducking
        )
        return segment.format
    }

    func begin(writingTo url: URL, voiceProcessing: Bool) async throws -> CaptureRun {
        if let current { return current.run }
        _ = try await start(writingTo: url, voiceProcessing: voiceProcessing)
        guard let current else { throw CancellationError() }
        return current.run
    }

    func observeRuntimeEvents(
        _ handler: @escaping @Sendable (CaptureRuntimeEvent) -> Void
    ) async {
        runtimeEventHandler = handler
        guard let current else { return }
        observeConfigurationChanges(for: current.run.id, engine: current.engine)
        await observeRecorderFailure(current.recorder, runID: current.run.id)
    }

    /// Compatibility for direct callers while the controller moves to typed events.
    func monitorRuntimeFailures(_ handler: @escaping @Sendable (String) -> Void) async {
        await observeRuntimeEvents { handler($0.message) }
    }

    func restart(
        after event: CaptureRuntimeEvent,
        writingTo nextSegmentURL: URL
    ) async throws -> CaptureRestartResult {
        guard event.retryability == .restartable else { return .stale }
        guard replacementRunID == nil else { return .stale }
        replacementRunID = event.runID
        defer {
            if replacementRunID == event.runID { replacementRunID = nil }
        }
        guard let context = await interrupt(runID: event.runID) else { return .stale }
        return try await resume(
            context,
            writingTo: nextSegmentURL,
            voiceProcessing: context.voiceProcessing
        )
    }

    func reconfigure(
        run: CaptureRun,
        writingTo nextSegmentURL: URL,
        voiceProcessing: Bool
    ) async throws -> CaptureRestartResult {
        guard replacementRunID == nil else { return .stale }
        replacementRunID = run.id
        defer {
            if replacementRunID == run.id { replacementRunID = nil }
        }
        guard let context = await interrupt(runID: run.id) else { return .stale }
        return try await resume(
            context,
            writingTo: nextSegmentURL,
            voiceProcessing: voiceProcessing
        )
    }

    private func resume(
        _ context: InterruptedPath,
        writingTo url: URL,
        voiceProcessing: Bool
    ) async throws -> CaptureRestartResult {
        guard !isFinishingSession, interrupted?.runID == context.runID else { return .stale }
        let segment: LiveSegment
        do {
            segment = try await startSegment(
                writingTo: url,
                segmentIndex: context.nextSegmentIndex,
                precedingEndHostTime: context.precedingEndHostTime,
                voiceProcessing: voiceProcessing,
                ducking: Self.transparentDucking
            )
        } catch is CancellationError {
            return .stale
        }
        guard current?.run == segment.run, !isFinishingSession else { return .stale }
        interrupted = nil
        return .restarted(segment.run)
    }

    private func startSegment(
        writingTo url: URL,
        segmentIndex: Int,
        precedingEndHostTime: UInt64?,
        voiceProcessing: Bool,
        ducking: AVAudioVoiceProcessingOtherAudioDuckingConfiguration
    ) async throws -> LiveSegment {
        guard !isFinishingSession else { throw CancellationError() }
        let engine = engines.engine(voiceProcessing: voiceProcessing)
        let input = engine.inputNode

        if voiceProcessing {
            if !didEnableVoiceProcessing {
                do {
                    // Only settable while the engine is stopped, and it enables voice
                    // processing on the output node too. Never disable it: AVFAudio has no
                    // property-listener quiescence contract, so toggling or destroying this
                    // graph can race its internal AUVoiceProcessingIO queue.
                    try input.setVoiceProcessingEnabled(true)
                    didEnableVoiceProcessing = true
                } catch {
                    throw Failure.voiceProcessingUnavailable(error.localizedDescription)
                }
            }
            input.voiceProcessingOtherAudioDuckingConfiguration = ducking
            let applied = input.voiceProcessingOtherAudioDuckingConfiguration
            AppLog.capture.debug(
                "ducking requested advanced=\(ducking.enableAdvancedDucking.boolValue, privacy: .public) level=\(ducking.duckingLevel.rawValue, privacy: .public); node reports advanced=\(applied.enableAdvancedDucking.boolValue, privacy: .public) level=\(applied.duckingLevel.rawValue, privacy: .public)"
            )
        } else {
            // This dedicated graph has never hosted Voice Processing IO. Keeping the modes
            // on separate retained engines avoids toggling the destructive processing unit.
            precondition(!input.isVoiceProcessingEnabled)
        }

        // Read the format *after* enabling voice processing. It changes the node's output
        // format, and anything configured from the format read before this line records
        // silence without reporting an error.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw Failure.unusableInputFormat(
                sampleRate: format.sampleRate, channelCount: format.channelCount)
        }

        // The graph differs between the two modes, and both shapes were arrived at by
        // measurement rather than by reading.
        //
        // With voice processing on, the engine must be left alone. Voice Processing IO is a
        // single unit that owns input and output together, and the header requires the
        // input node's output format and the output node's input format to match. Attaching
        // the main mixer introduces a connection at the *output device's* format, and the
        // unit then refuses to initialise: -10875, kAudioUnitErr_FailedInitialization.
        //
        // With it off there is no such unit, and an engine whose only client is a tap on the
        // input node never renders at all — that configuration produced a file of exactly
        // zero frames. It needs a pull from the output side, so the input is routed to the
        // main mixer at its own format, with the mixer silenced so nothing reaches the
        // speakers and loops back into the microphone.
        if !voiceProcessing {
            engine.connect(input, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
        }

        // Echo cancellation is what makes this track "me" rather than "the room". Without it
        // the speakers are in here too, and the manifest has to say so.
        let recorder = try TrackRecorder(
            label: "mic",
            url: url,
            source: .microphone,
            segmentIndex: segmentIndex,
            sampleRate: format.sampleRate,
            content: voiceProcessing ? .local : .mixed,
            precedingSegmentEndHostTime: precedingEndHostTime
        )
        let run = CaptureRun(id: UUID(), segmentIndex: segmentIndex)
        let operationID = UUID()
        self.operationID = operationID
        preparingRecorder = recorder
        preparingEngine = engine
        preparingURL = url
        await recorder.start()
        guard self.operationID == operationID, !isFinishingSession,
            preparingRecorder != nil, preparingEngine === engine
        else {
            throw CancellationError()
        }

        let trackInput = recorder.input
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) { buffer, when in
            // Real-time context: one coordinated timestamp/boundary/sample handoff into
            // preallocated SPSC rings, nothing else.
            trackInput.write(
                buffer,
                atHostTime: when.isHostTimeValid ? when.hostTime : nil
            )
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            _ = await recorder.finish()
            guard self.operationID == operationID, !isFinishingSession else {
                throw CancellationError()
            }
            preparingRecorder = nil
            preparingEngine = nil
            preparingURL = nil
            try? FileManager.default.removeItem(at: url)
            throw Failure.engineFailed(error.localizedDescription)
        }

        let segment = LiveSegment(
            run: run,
            engine: engine,
            recorder: recorder,
            format: format,
            voiceProcessing: voiceProcessing
        )
        preparingRecorder = nil
        preparingEngine = nil
        preparingURL = nil
        current = segment
        if runtimeEventHandler != nil {
            observeConfigurationChanges(for: run.id, engine: engine)
            await observeRecorderFailure(recorder, runID: run.id)
        }
        guard self.operationID == operationID, current?.run == run, !isFinishingSession else {
            throw CancellationError()
        }

        AppLog.capture.notice(
            "microphone capture started at \(format.sampleRate, format: .fixed(precision: 0), privacy: .public) Hz, \(format.channelCount, privacy: .public) channel(s), voice processing \(input.isVoiceProcessingEnabled ? "on" : "off", privacy: .public); output node expects \(engine.outputNode.inputFormat(forBus: 0).sampleRate, format: .fixed(precision: 0), privacy: .public) Hz, \(engine.outputNode.inputFormat(forBus: 0).channelCount, privacy: .public) channel(s)"
        )
        return segment
    }

    func monitorFirstSample(_ handler: @escaping @Sendable (UInt64) -> Void) async {
        guard let current else { return }
        await current.recorder.observeFirstSample(handler)
    }

    func stop() async -> TrackRecorder.Completion? {
        await finishSession().last
    }

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

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }

        let live = current
        if let live {
            live.recorder.input.closeProducer()
            stopProducer(live)
        }
        current = nil
        let retiringRecorder = self.retiringRecorder
        self.retiringRecorder = nil
        let preparingRecorder = self.preparingRecorder
        let preparingEngine = self.preparingEngine
        let preparingURL = self.preparingURL
        self.preparingRecorder = nil
        self.preparingEngine = nil
        self.preparingURL = nil

        // Voice processing is deliberately left enabled. Turning it off here reconfigures
        // the audio unit at the exact moment everything around it is being torn down, and
        // AVFAudio's own property listener then fired against freed memory — a reproducible
        // SIGSEGV in AVAudioIOUnit::IOUnitPropertyListener. A stopped engine captures
        // nothing either way, so the only thing switching it off achieved was the crash,
        // and leaving it on makes the next recording start sooner.

        if let live { appendCompleted(await live.recorder.finish()) }
        if let retiringRecorder { appendCompleted(await retiringRecorder.finish()) }
        if let preparingRecorder {
            _ = await preparingRecorder.finish()
            if let preparingURL { try? FileManager.default.removeItem(at: preparingURL) }
        }
        _ = preparingEngine
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

    private func interrupt(runID: UUID) async -> InterruptedPath? {
        if let interrupted, interrupted.runID == runID { return interrupted }
        guard !isFinishingSession, let segment = current, segment.run.id == runID else {
            return nil
        }

        removeConfigurationObserver()
        current = nil
        let operationID = UUID()
        self.operationID = operationID
        retiringRecorder = segment.recorder
        segment.recorder.input.closeProducer()
        stopProducer(segment)
        while segment.recorder.input.hasActiveProducerWrite { await Task.yield() }
        guard self.operationID == operationID, !isFinishingSession else { return nil }
        let context = InterruptedPath(
            runID: runID,
            nextSegmentIndex: segment.run.segmentIndex + 1,
            precedingEndHostTime: segment.recorder.input.lastSampleEndHostTime,
            voiceProcessing: segment.voiceProcessing
        )
        interrupted = context
        let completion = await segment.recorder.finish()
        guard self.operationID == operationID, !isFinishingSession else { return nil }
        retiringRecorder = nil
        appendCompleted(completion)
        return context
    }

    private func stopProducer(_ segment: LiveSegment) {
        segment.engine.inputNode.removeTap(onBus: 0)
        segment.engine.stop()
    }

    private func appendCompleted(_ completion: TrackRecorder.Completion) {
        guard !completedSegments.contains(where: { $0.summary.url == completion.summary.url })
        else {
            return
        }
        completedSegments.append(completion)
        let summary = completion.summary
        AppLog.capture.notice(
            "microphone track: \(summary.duration, format: .fixed(precision: 1), privacy: .public) s, peak \(summary.peakAmplitude, format: .fixed(precision: 4), privacy: .public), dropped \(summary.droppedSampleCount, privacy: .public) samples"
        )
        if summary.isSilent {
            AppLog.capture.error(
                "microphone track is silent; check the input device and the microphone permission")
        }
        if summary.isClipped {
            AppLog.capture.error(
                "microphone input clipped at \(summary.peakAmplitude, format: .fixed(precision: 2), privacy: .public); lower the input volume in System Settings › Sound"
            )
        } else if summary.isTooLoud {
            AppLog.capture.notice(
                "microphone input peaked at \(summary.peakAmplitude, format: .fixed(precision: 3), privacy: .public), within a decibel of clipping; consider lowering the input volume"
            )
        }
    }

    /// Plugging in headphones changes the default device and stops the engine underneath us.
    private func observeConfigurationChanges(for runID: UUID, engine: AVAudioEngine) {
        removeConfigurationObserver()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleConfigurationChange(runID: runID) }
        }
    }

    private func removeConfigurationObserver() {
        guard let configurationObserver else { return }
        NotificationCenter.default.removeObserver(configurationObserver)
        self.configurationObserver = nil
    }

    private func handleConfigurationChange(runID: UUID) {
        guard current?.run.id == runID else { return }
        reportRuntimeEvent(
            runID: runID,
            message: "The microphone audio configuration changed.",
            retryability: .restartable
        )
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

    private func reportRuntimeEvent(
        runID: UUID,
        message: String,
        retryability: CaptureRuntimeEvent.Retryability
    ) {
        guard current?.run.id == runID, let runtimeEventHandler,
            reportedRunIDs.insert(runID).inserted
        else { return }
        AppLog.capture.error("\(message, privacy: .public)")
        runtimeEventHandler(
            CaptureRuntimeEvent(runID: runID, message: message, retryability: retryability))
    }
}
