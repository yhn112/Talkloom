import AVFoundation
import CoreAudio
import Foundation

/// Records everything the machine plays, through a CoreAudio process tap.
///
/// A process tap rather than ScreenCaptureKit because SCK asks for Screen Recording, a
/// heavyweight permission for something that only needs audio. The call sequence and the
/// header citations behind every constant used here are in `docs/system-audio-capture.md`.
///
/// A tap produces nothing on its own: it has to be wrapped in a private aggregate device.
actor SystemAudioCapture: SystemAudioCapturing {
    enum Failure: Error, LocalizedError {
        case tapCreationFailed(String)
        case tapFormatUnavailable(String)
        case tapUIDUnavailable(String)
        case aggregateCreationFailed(String)
        case ioProcCreationFailed(String)
        case deviceStartFailed(String)
        case unusableTapFormat(sampleRate: Double, channelCount: UInt32)

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let detail):
                "Could not tap the system audio (\(detail)). Grant Transcriber access under System Settings › Privacy & Security › Audio Recording."
            case .tapFormatUnavailable(let detail):
                "The system audio tap did not report its format (\(detail))."
            case .tapUIDUnavailable(let detail):
                "The system audio tap did not report its UID (\(detail))."
            case .aggregateCreationFailed(let detail):
                "Could not create the aggregate device for the system audio tap (\(detail))."
            case .ioProcCreationFailed(let detail):
                "Could not attach to the system audio tap (\(detail))."
            case .deviceStartFailed(let detail):
                "Could not start the system audio tap (\(detail))."
            case .unusableTapFormat(let sampleRate, let channelCount):
                "The system audio tap reported an unusable format (\(sampleRate) Hz, \(channelCount) channels)."
            }
        }
    }

    /// One live tap: the objects that have to be torn down together, in this order.
    private struct Tap {
        var processTap: AudioHardwareTap
        var aggregateDevice: AudioHardwareAggregateDevice
        var ioProcID: AudioDeviceIOProcID?
        var format: AudioStreamBasicDescription
    }

    /// The IO block is dispatched onto this queue. The header is explicit that IO blocks
    /// are dispatched *synchronously*, so this is still a real-time context — the queue
    /// buys nothing that would make allocating or locking acceptable.
    private let ioQueue = DispatchQueue(
        label: "me.diskin.Transcriber.system-audio", qos: .userInitiated)

    private struct LiveSegment {
        let run: CaptureRun
        let tap: Tap
        let recorder: TrackRecorder
    }

    private struct InterruptedPath {
        let runID: UUID
        let nextSegmentIndex: Int
        let precedingEndHostTime: UInt64?
    }

    private var current: LiveSegment?
    private var interrupted: InterruptedPath?
    private var completedSegments: [TrackRecorder.Completion] = []
    private var retiringRecorder: TrackRecorder?
    private var preparingRecorder: TrackRecorder?
    private var preparingTap: Tap?
    private var preparingURL: URL?
    private var watchdogTask: Task<Void, Never>?
    private var lastObservedSampleCount = 0
    private var stalledSeconds = 0
    private var runtimeEventHandler: (@Sendable (CaptureRuntimeEvent) -> Void)?
    private var reportedRunIDs: Set<UUID> = []
    private var operationID = UUID()
    private var replacementRunID: UUID?
    private var isFinishingSession = false
    private var finishWaiters: [CheckedContinuation<[TrackRecorder.Completion], Never>] = []

    /// Last resort for the tap and its aggregate device.
    ///
    /// `stop()` is the ordinary path and does this properly, flushing the file as well.
    /// This exists because an aggregate device that is never destroyed outlives the process
    /// that made it — it becomes litter in the user's audio system, visible to every other
    /// app, and nothing cleans it up. Dropping this actor without stopping it should not
    /// leave that behind.
    deinit {
        if let current {
            AppLog.capture.error(
                "the system audio tap was dropped without being stopped; tearing it down")
            Self.destroy(current.tap, context: "deinit fallback")
        }
        if let preparingTap {
            Self.destroy(preparingTap, context: "deinit preparation fallback")
        }
        watchdogTask?.cancel()
    }

    /// Starts capture into `url` and returns the sample rate the tap reported.
    @discardableResult
    func start(writingTo url: URL) async throws -> Double {
        if let current { return current.tap.format.mSampleRate }
        guard interrupted == nil, retiringRecorder == nil, preparingRecorder == nil else {
            throw CancellationError()
        }
        completedSegments = []
        interrupted = nil
        let segment = try await startSegment(
            writingTo: url,
            segmentIndex: 0,
            precedingEndHostTime: nil
        )
        return segment.tap.format.mSampleRate
    }

    func begin(writingTo url: URL) async throws -> CaptureRun {
        if let current { return current.run }
        _ = try await start(writingTo: url)
        guard let current else { throw CancellationError() }
        return current.run
    }

    func observeRuntimeEvents(
        _ handler: @escaping @Sendable (CaptureRuntimeEvent) -> Void
    ) async {
        runtimeEventHandler = handler
        guard let current else { return }
        startWatchdog(for: current.run.id)
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
        guard !isFinishingSession, interrupted?.runID == context.runID else { return .stale }
        let segment: LiveSegment
        do {
            segment = try await startSegment(
                writingTo: nextSegmentURL,
                segmentIndex: context.nextSegmentIndex,
                precedingEndHostTime: context.precedingEndHostTime
            )
        } catch is CancellationError {
            return .stale
        }
        guard current?.run == segment.run, !isFinishingSession else { return .stale }
        interrupted = nil
        return .restarted(segment.run)
    }

    func monitorFirstSample(_ handler: @escaping @Sendable (UInt64) -> Void) async {
        guard let current else { return }
        await current.recorder.observeFirstSample(handler)
    }

    /// Actively proves that this running tap carries output before microphone AEC can erase
    /// that same output from the only other track.
    func verifySignal() async throws -> Bool {
        guard let current else { return false }
        let observation = await current.recorder.beginSignalObservation(
            above: SystemAudioProbe.signalThreshold)
        do {
            try await SystemAudioProbe.play()
        } catch {
            await current.recorder.cancelSignalObservation(observation)
            throw error
        }
        return await current.recorder.waitForSignal(
            observation, timeout: SystemAudioProbe.observationTimeout)
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
        cancelWatchdog()

        let live = current
        current = nil
        if let live {
            live.recorder.input.closeProducer()
            Self.destroy(live.tap, context: "stopping system audio capture")
        }
        let retiringRecorder = self.retiringRecorder
        self.retiringRecorder = nil
        let preparingRecorder = self.preparingRecorder
        let preparingTap = self.preparingTap
        let preparingURL = self.preparingURL
        self.preparingRecorder = nil
        self.preparingTap = nil
        self.preparingURL = nil
        if let preparingTap {
            Self.destroy(preparingTap, context: "stopping system audio preparation")
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

    private func startSegment(
        writingTo url: URL,
        segmentIndex: Int,
        precedingEndHostTime: UInt64?
    ) async throws -> LiveSegment {
        guard !isFinishingSession else { throw CancellationError() }
        let probe = try createTap()
        let sampleRate = probe.format.mSampleRate
        guard sampleRate > 0, probe.format.mChannelsPerFrame > 0 else {
            Self.destroy(probe, context: "rejecting an unusable tap format")
            throw Failure.unusableTapFormat(
                sampleRate: sampleRate,
                channelCount: probe.format.mChannelsPerFrame
            )
        }

        let recorder: TrackRecorder
        do {
            recorder = try TrackRecorder(
                label: "system",
                url: url,
                source: .systemAudio,
                segmentIndex: segmentIndex,
                sampleRate: sampleRate,
                content: .remote,
                precedingSegmentEndHostTime: precedingEndHostTime
            )
        } catch {
            Self.destroy(probe, context: "rolling back track recorder creation")
            throw error
        }

        let run = CaptureRun(id: UUID(), segmentIndex: segmentIndex)
        let operationID = UUID()
        self.operationID = operationID
        preparingRecorder = recorder
        preparingTap = probe
        preparingURL = url
        await recorder.start()
        guard self.operationID == operationID, !isFinishingSession,
            preparingRecorder != nil, var running = preparingTap
        else { throw CancellationError() }

        do {
            try attachAndStart(&running, feeding: recorder.input)
        } catch {
            preparingTap = nil
            Self.destroy(running, context: "rolling back a failed system audio start")
            _ = await recorder.finish()
            guard self.operationID == operationID, !isFinishingSession else {
                throw CancellationError()
            }
            preparingRecorder = nil
            preparingURL = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        let segment = LiveSegment(run: run, tap: running, recorder: recorder)
        preparingRecorder = nil
        preparingTap = nil
        preparingURL = nil
        current = segment
        lastObservedSampleCount = 0
        stalledSeconds = 0
        if runtimeEventHandler != nil {
            startWatchdog(for: run.id)
            await observeRecorderFailure(recorder, runID: run.id)
        }
        guard self.operationID == operationID, current?.run == run, !isFinishingSession else {
            throw CancellationError()
        }

        let format = running.format
        AppLog.capture.notice(
            "system audio tap format: \(format.mSampleRate, format: .fixed(precision: 0), privacy: .public) Hz, \(format.mChannelsPerFrame, privacy: .public) ch, \(format.mBytesPerFrame, privacy: .public) bytes/frame, \(format.mFramesPerPacket, privacy: .public) frames/packet, flags 0x\(String(format.mFormatFlags, radix: 16), privacy: .public)"
        )
        return segment
    }

    private func interrupt(runID: UUID) async -> InterruptedPath? {
        if let interrupted, interrupted.runID == runID { return interrupted }
        guard !isFinishingSession, let segment = current, segment.run.id == runID else {
            return nil
        }

        cancelWatchdog()
        current = nil
        let operationID = UUID()
        self.operationID = operationID
        retiringRecorder = segment.recorder
        segment.recorder.input.closeProducer()
        Self.destroy(segment.tap, context: "restarting system audio capture")
        while segment.recorder.input.hasActiveProducerWrite { await Task.yield() }
        guard self.operationID == operationID, !isFinishingSession else { return nil }
        let context = InterruptedPath(
            runID: runID,
            nextSegmentIndex: segment.run.segmentIndex + 1,
            precedingEndHostTime: segment.recorder.input.lastSampleEndHostTime
        )
        interrupted = context
        let completion = await finalizedCompletion(for: segment.recorder)
        guard self.operationID == operationID, !isFinishingSession else { return nil }
        retiringRecorder = nil
        appendCompleted(completion)
        return context
    }

    private func finalizedCompletion(for recorder: TrackRecorder) async -> TrackRecorder.Completion
    {
        let shape = recorder.input.lastBufferListShape
        AppLog.capture.debug(
            "system audio last block: \(shape.buffers, privacy: .public) buffer(s), \(shape.channels, privacy: .public) ch, \(shape.byteCount, privacy: .public) bytes"
        )
        let refused = recorder.input.unexpectedLayoutCount
        if refused > 0 {
            AppLog.capture.error(
                "the system audio device delivered \(refused, privacy: .public) block(s) in an unexpected layout, and they were dropped; the last was \(shape.buffers, privacy: .public) buffer(s) of \(shape.channels, privacy: .public) channel(s)"
            )
        }
        var completion = await recorder.finish()
        if refused > 0, completion.failure == nil {
            completion = TrackRecorder.Completion(
                summary: completion.summary,
                failure: .unexpectedBufferLayout(label: "system audio", blockCount: refused)
            )
        }
        return completion
    }

    private func appendCompleted(_ completion: TrackRecorder.Completion) {
        guard !completedSegments.contains(where: { $0.summary.url == completion.summary.url })
        else {
            return
        }
        completedSegments.append(completion)
        let summary = completion.summary
        AppLog.capture.notice(
            "system audio track: \(summary.duration, format: .fixed(precision: 1), privacy: .public) s, peak \(summary.peakAmplitude, format: .fixed(precision: 4), privacy: .public), dropped \(summary.droppedSampleCount, privacy: .public) samples"
        )
        if summary.isSilent {
            AppLog.capture.error(
                "system audio track is silent; nothing was playing, or the Audio Recording permission is missing"
            )
        }
    }

    // MARK: - Building the tap

    private func createTap() throws -> Tap {
        // An empty exclusion list means every process that outputs audio. Mono because the
        // mixdown is what ASR wants anyway, so nothing downstream has to fold it.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Transcriber system audio"
        description.isPrivate = true
        // Leave the system's own output alone. Muting the tapped processes would silence
        // the meeting for the user, which is a recorder, not a mute button.
        description.muteBehavior = .unmuted

        let processTap: AudioHardwareTap
        do {
            guard
                let created = try AudioHardwareSystem.shared.makeProcessTap(
                    description: description)
            else {
                throw Failure.tapCreationFailed("CoreAudio returned no tap object")
            }
            processTap = created
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.tapCreationFailed(Self.describe(error))
        }

        do {
            // Read the format the tap actually reports rather than assuming one. Assuming
            // here is what produces a valid file full of silence.
            let format: AudioStreamBasicDescription
            do {
                format = try processTap.format
            } catch {
                throw Failure.tapFormatUnavailable(Self.describe(error))
            }
            let tapUID: String
            do {
                tapUID = try processTap.uid
            } catch {
                throw Failure.tapUIDUnavailable(Self.describe(error))
            }
            let aggregateDevice = try createAggregate(around: tapUID)
            return Tap(
                processTap: processTap,
                aggregateDevice: aggregateDevice,
                ioProcID: nil,
                format: format
            )
        } catch {
            Self.destroyProcessTap(processTap, context: "rolling back tap creation")
            throw error
        }
    }

    private func createAggregate(around tapUID: String) throws -> AudioHardwareAggregateDevice {
        // The tap is the only member. Adding the default output device as a sub-device is
        // the widely published recipe, and it costs more than it gives: the aggregate then
        // carries that device's own input stream as well, so the IO block receives two
        // buffers and the tap is not the first one. Measured with Voice Processing IO
        // running: 2 buffers, the first carrying 6 channels of the built-in output device.
        // Without the sub-device there is exactly one buffer and it is the tap.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transcriber System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            // Private, so it never appears in Sound settings — and the header requires it
            // for tap auto-start to be honoured.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Start immediately rather than waiting for a process to make a sound. Auto-start
            // delays the first sample until something plays, which leaves the track shorter
            // than the meeting and its beginning unaccounted for; recording the leading
            // silence costs 96 kB per second and keeps the timeline continuous.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        do {
            guard
                let aggregate = try AudioHardwareSystem.shared.makeAggregateDevice(
                    description: description)
            else {
                throw Failure.aggregateCreationFailed(
                    "CoreAudio returned no aggregate device object")
            }
            return aggregate
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.aggregateCreationFailed(Self.describe(error))
        }
    }

    private func attachAndStart(_ tap: inout Tap, feeding trackInput: TrackInput) throws {
        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID, tap.aggregateDevice.id, ioQueue
        ) { _, inputData, inputTime, _, _ in
            // Real-time context: one coordinated timestamp/boundary/sample handoff into
            // preallocated SPSC rings, nothing else.
            trackInput.write(
                inputData,
                atHostTime: inputTime.pointee.mFlags.contains(.hostTimeValid)
                    ? inputTime.pointee.mHostTime : nil
            )
        }
        guard createStatus == noErr, let ioProcID else {
            throw Failure.ioProcCreationFailed(Self.describe(createStatus))
        }
        tap.ioProcID = ioProcID

        do {
            try tap.aggregateDevice.start(IOProcID: ioProcID)
        } catch {
            let destroyStatus = AudioDeviceDestroyIOProcID(tap.aggregateDevice.id, ioProcID)
            if destroyStatus != noErr {
                AppLog.capture.error(
                    "could not destroy the IOProc after device start failed: \(Self.describe(destroyStatus), privacy: .public)"
                )
            } else {
                tap.ioProcID = nil
            }
            throw Failure.deviceStartFailed(Self.describe(error))
        }
    }

    /// Tears a tap down in the order the objects depend on each other. An aggregate device
    /// that is never destroyed outlives the process.
    private static func destroy(_ tap: Tap, context: String) {
        if let ioProcID = tap.ioProcID {
            do {
                try tap.aggregateDevice.stop(IOProcID: ioProcID)
            } catch {
                AppLog.capture.error(
                    "\(context, privacy: .public): could not stop the aggregate device: \(Self.describe(error), privacy: .public)"
                )
            }
            let status = AudioDeviceDestroyIOProcID(tap.aggregateDevice.id, ioProcID)
            if status != noErr {
                AppLog.capture.error(
                    "\(context, privacy: .public): could not destroy the IOProc: \(Self.describe(status), privacy: .public)"
                )
            }
        }
        do {
            try AudioHardwareSystem.shared.destroyAggregateDevice(tap.aggregateDevice)
        } catch {
            AppLog.capture.error(
                "\(context, privacy: .public): could not destroy the aggregate device: \(Self.describe(error), privacy: .public)"
            )
        }
        Self.destroyProcessTap(tap.processTap, context: context)
    }

    private static func destroyProcessTap(_ tap: AudioHardwareTap, context: String) {
        do {
            try AudioHardwareSystem.shared.destroyProcessTap(tap)
        } catch {
            AppLog.capture.error(
                "\(context, privacy: .public): could not destroy the process tap: \(Self.describe(error), privacy: .public)"
            )
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let hardwareError = error as? AudioHardwareError {
            return describe(hardwareError.error)
        }
        return error.localizedDescription
    }

    /// OSStatus values in this API are four-character codes far more often than numbers.
    private static func describe(_ status: OSStatus) -> String {
        let bytes = [24, 16, 8, 0].map {
            UInt8((UInt32(bitPattern: status) >> UInt32($0)) & 0xFF)
        }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            return "status \(status)"
        }
        return "'\(String(decoding: bytes, as: UTF8.self))'"
    }

    // MARK: - Surviving a dead tap

    /// How long the tap may deliver nothing before it is presumed dead. With auto-start
    /// off the tap produces frames continuously, silence included, so a gap this long is
    /// not a quiet moment — it is a stopped stream.
    private static let stallTolerance = 2

    private func startWatchdog(for runID: UUID) {
        cancelWatchdog()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.checkForStall(runID: runID)
            }
        }
    }

    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// Watches the sample count rather than the default output device.
    ///
    /// Changing the output device is the documented way to kill a tap, but it is not the
    /// only one, and listening for it means rebuilding a perfectly healthy tap every time
    /// someone plugs in headphones — a gap in the recording to fix a problem that may not
    /// have happened. A tap that has stopped delivering is the thing that actually matters,
    /// it covers every cause, and nothing else reports it: the file simply goes quiet.
    private func checkForStall(runID: UUID) async {
        guard let current, current.run.id == runID else { return }

        let refused = current.recorder.input.unexpectedLayoutCount
        if refused > 0 {
            reportRuntimeEvent(
                runID: runID,
                message: "The system audio tap delivered \(refused) unsupported buffer block(s).",
                retryability: .restartable
            )
            return
        }

        let received = current.recorder.input.ring.totalSampleCount
        if received > lastObservedSampleCount {
            lastObservedSampleCount = received
            stalledSeconds = 0
            return
        }

        stalledSeconds += 1
        guard stalledSeconds >= Self.stallTolerance else { return }
        stalledSeconds = 0

        reportRuntimeEvent(
            runID: runID,
            message:
                "The system audio tap stopped delivering samples for \(Self.stallTolerance) seconds.",
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
        cancelWatchdog()
        runtimeEventHandler(
            CaptureRuntimeEvent(runID: runID, message: message, retryability: retryability))
    }
}
