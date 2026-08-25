import AVFoundation
import CoreAudio
import Foundation
import TranscriberCore

/// A system-audio generation takes no configuration: there is one way to tap the machine's
/// output, and the tap reports what it will deliver.
struct SystemAudioOptions: Sendable {
    init() {}
}

/// Produces system-audio generations through a CoreAudio process tap.
///
/// A process tap rather than ScreenCaptureKit because SCK asks for Screen Recording, a
/// heavyweight permission for something that only needs audio. The call sequence and the
/// header citations behind every constant used here are in `docs/system-audio-capture.md`.
///
/// A tap produces nothing on its own: it has to be wrapped in a private aggregate device.
final class SystemAudioProducer: SegmentProducer {
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
                "Could not start the system audio device (\(detail))."
            case .unusableTapFormat(let sampleRate, let channelCount):
                "The system audio tap reported an unusable format (\(sampleRate) Hz, \(channelCount) channels)."
            }
        }
    }

    /// One live tap: the objects that have to be torn down together, in this order.
    ///
    /// Each field is cleared as its object is destroyed, so a teardown that partly failed
    /// says exactly what is still held rather than being retried blind.
    final class Generation {
        var processTap: AudioHardwareTap?
        var aggregateDevice: AudioHardwareAggregateDevice?
        var ioProcID: AudioDeviceIOProcID?
        let format: AudioStreamBasicDescription

        /// Set when the owner has asked for this generation back. Until then it is live and
        /// must not be swept up by another generation's teardown.
        var isRetired = false

        var isFullyReleased: Bool {
            processTap == nil && aggregateDevice == nil && ioProcID == nil
        }

        init(
            processTap: AudioHardwareTap?,
            aggregateDevice: AudioHardwareAggregateDevice?,
            ioProcID: AudioDeviceIOProcID?,
            format: AudioStreamBasicDescription
        ) {
            self.processTap = processTap
            self.aggregateDevice = aggregateDevice
            self.ioProcID = ioProcID
            self.format = format
        }
    }

    /// How long the tap may deliver nothing before it is presumed dead. With auto-start
    /// off the tap produces frames continuously, silence included, so a gap this long is
    /// not a quiet moment — it is a stopped stream.
    private static let stallTolerance = 2

    /// The IO block is dispatched onto this queue. The header is explicit that IO blocks
    /// are dispatched *synchronously*, so this is still a real-time context — the queue
    /// buys nothing that would make allocating or locking acceptable.
    private let ioQueue = DispatchQueue(
        label: "me.diskin.Transcriber.system-audio", qos: .userInitiated)

    /// Every generation this producer has acquired and not yet fully given back.
    ///
    /// An aggregate device that is never destroyed outlives the process that made it: it
    /// becomes litter in the user's audio system, visible to every other app, and nothing
    /// cleans it up. Logging a failed teardown and dropping the handle guarantees that
    /// outcome, so a handle stays here — retried on the next teardown, and finally in
    /// `deinit` — until CoreAudio accepts it.
    private var outstanding: [Generation] = []
    private var watchdogTask: Task<Void, Never>?

    let descriptor = CaptureTrackDescriptor(
        trackLabel: "system",
        name: "system audio",
        source: .systemAudio
    )

    init() {}

    deinit {
        watchdogTask?.cancel()
        for generation in outstanding {
            if !generation.isRetired {
                AppLog.capture.error(
                    "the system audio tap was dropped without being stopped; tearing it down")
            }
            Self.destroy(generation, context: "producer teardown")
        }
        let stranded = outstanding.filter { !$0.isFullyReleased }.count
        if stranded > 0 {
            AppLog.capture.error(
                "\(stranded, privacy: .public) system audio resource(s) could not be destroyed and are being abandoned at exit"
            )
        }
    }

    func content(for options: SystemAudioOptions) -> TrackContent { .remote }

    func acquire(_ options: SystemAudioOptions) throws -> (Generation, SegmentFormat) {
        sweepRetired(context: "before acquiring a system audio tap")

        let generation = try createTap()
        outstanding.append(generation)
        let format = SegmentFormat(
            sampleRate: generation.format.mSampleRate,
            channelCount: generation.format.mChannelsPerFrame
        )
        guard format.sampleRate > 0, format.channelCount > 0 else {
            release(generation, context: "rejecting an unusable tap format")
            throw Failure.unusableTapFormat(
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            )
        }
        return (generation, format)
    }

    func attach(_ generation: Generation, to input: TrackInput) throws {
        guard let aggregateDevice = generation.aggregateDevice else {
            throw Failure.ioProcCreationFailed("the aggregate device was already destroyed")
        }

        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID, aggregateDevice.id, ioQueue
        ) { _, inputData, inputTime, _, _ in
            // Real-time context: one coordinated timestamp/boundary/sample handoff into
            // preallocated SPSC rings, nothing else.
            input.write(
                inputData,
                atHostTime: inputTime.pointee.mFlags.contains(.hostTimeValid)
                    ? inputTime.pointee.mHostTime : nil
            )
        }
        guard createStatus == noErr, let ioProcID else {
            throw Failure.ioProcCreationFailed(Self.describe(createStatus))
        }
        generation.ioProcID = ioProcID

        do {
            try aggregateDevice.start(IOProcID: ioProcID)
        } catch {
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
            if destroyStatus != noErr {
                AppLog.capture.error(
                    "could not destroy the IOProc after device start failed: \(Self.describe(destroyStatus), privacy: .public)"
                )
            } else {
                generation.ioProcID = nil
            }
            throw Failure.deviceStartFailed(Self.describe(error))
        }
    }

    func release(_ generation: Generation, context: String) {
        generation.isRetired = true
        sweepRetired(context: context)
    }

    /// Destroys every retired generation, and keeps whatever CoreAudio still refuses.
    ///
    /// A live generation is never touched here: during a restart the replacement is acquired
    /// while its predecessor is still being given back, and sweeping both would tear down the
    /// tap that is already recording again.
    private func sweepRetired(context: String) {
        for generation in outstanding where generation.isRetired {
            Self.destroy(generation, context: context)
        }
        outstanding.removeAll { $0.isRetired && $0.isFullyReleased }
        let held = outstanding.filter(\.isRetired).count
        if held > 0 {
            AppLog.capture.error(
                "\(context, privacy: .public): \(held, privacy: .public) system audio resource(s) are still held and will be retried"
            )
        }
    }

    func beginWatching(
        _ generation: Generation,
        input: TrackInput,
        report: @escaping @Sendable (String, CaptureRuntimeEvent.Retryability) -> Void
    ) {
        stopWatching()
        // Nothing of this producer is captured: the task holds only the ring it reads, the
        // way out it reports through, and its own counters. Those counters are locals rather
        // than producer state because they belong to this generation and to this task, and
        // nothing outside it may read them.
        let stallTolerance = Self.stallTolerance
        watchdogTask = Task {
            var lastObservedSampleCount = 0
            var stalledSeconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }

                let refused = input.unexpectedLayoutCount
                if refused > 0 {
                    report(
                        "The system audio tap delivered \(refused) unsupported buffer block(s).",
                        .restartable)
                    return
                }

                let received = input.ring.totalSampleCount
                if received > lastObservedSampleCount {
                    lastObservedSampleCount = received
                    stalledSeconds = 0
                    continue
                }

                stalledSeconds += 1
                guard stalledSeconds >= stallTolerance else { continue }
                report(
                    "The system audio tap stopped delivering samples for \(stallTolerance) seconds.",
                    .restartable)
                return
            }
        }
    }

    func stopWatching() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// Blocks the tap refused for arriving in an unexpected layout are the track's problem,
    /// not the drain's, so they are folded into the completion here.
    func amend(
        _ completion: TrackRecorder.Completion,
        from input: TrackInput
    ) -> TrackRecorder.Completion {
        let shape = input.lastBufferListShape
        AppLog.capture.debug(
            "system audio last block: \(shape.buffers, privacy: .public) buffer(s), \(shape.channels, privacy: .public) ch, \(shape.byteCount, privacy: .public) bytes"
        )
        let refused = input.unexpectedLayoutCount
        guard refused > 0 else { return completion }
        AppLog.capture.error(
            "the system audio device delivered \(refused, privacy: .public) block(s) in an unexpected layout, and they were dropped; the last was \(shape.buffers, privacy: .public) buffer(s) of \(shape.channels, privacy: .public) channel(s)"
        )
        guard completion.failure == nil else { return completion }
        return TrackRecorder.Completion(
            summary: completion.summary,
            failure: .unexpectedBufferLayout(label: "system audio", blockCount: refused)
        )
    }

    func logStarted(_ generation: Generation, format: SegmentFormat) {
        let tapFormat = generation.format
        AppLog.capture.notice(
            "system audio tap format: \(tapFormat.mSampleRate, format: .fixed(precision: 0), privacy: .public) Hz, \(tapFormat.mChannelsPerFrame, privacy: .public) ch, \(tapFormat.mBytesPerFrame, privacy: .public) bytes/frame, \(tapFormat.mFramesPerPacket, privacy: .public) frames/packet, flags 0x\(String(tapFormat.mFormatFlags, radix: 16), privacy: .public)"
        )
    }

    func logCompleted(_ summary: TrackRecorder.Summary) {
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

    private func createTap() throws -> Generation {
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
            return Generation(
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

    /// Tears a generation down in the order the objects depend on each other, clearing each
    /// field as its object goes, so a partly failed teardown says exactly what is still held.
    ///
    /// Every step is attempted even when an earlier one failed: a leaked IOProc is not a
    /// reason to leak the aggregate device as well.
    private static func destroy(_ generation: Generation, context: String) {
        let remaining = generation
        if let aggregateDevice = remaining.aggregateDevice, let ioProcID = remaining.ioProcID {
            do {
                try aggregateDevice.stop(IOProcID: ioProcID)
            } catch {
                AppLog.capture.error(
                    "\(context, privacy: .public): could not stop the aggregate device: \(Self.describe(error), privacy: .public)"
                )
            }
            let status = AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
            if status == noErr {
                remaining.ioProcID = nil
            } else {
                AppLog.capture.error(
                    "\(context, privacy: .public): could not destroy the IOProc: \(Self.describe(status), privacy: .public)"
                )
            }
        } else {
            // Nothing left to destroy it against; the aggregate took it with it.
            remaining.ioProcID = nil
        }

        if let aggregateDevice = remaining.aggregateDevice {
            do {
                try AudioHardwareSystem.shared.destroyAggregateDevice(aggregateDevice)
                remaining.aggregateDevice = nil
            } catch {
                AppLog.capture.error(
                    "\(context, privacy: .public): could not destroy the aggregate device: \(Self.describe(error), privacy: .public)"
                )
            }
        }

        if let processTap = remaining.processTap {
            if Self.destroyProcessTap(processTap, context: context) {
                remaining.processTap = nil
            }
        }
    }

    @discardableResult
    private static func destroyProcessTap(_ tap: AudioHardwareTap, context: String) -> Bool {
        do {
            try AudioHardwareSystem.shared.destroyProcessTap(tap)
            return true
        } catch {
            AppLog.capture.error(
                "\(context, privacy: .public): could not destroy the process tap: \(Self.describe(error), privacy: .public)"
            )
            return false
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
}

/// The system-audio track: one lifecycle, one producer.
typealias SystemAudioCapture = TrackCapture<SystemAudioProducer>

extension TrackCapture where Producer == SystemAudioProducer {
    /// Starts capture into `url` and reports the format the tap chose.
    @discardableResult
    func start(writingTo url: URL) async throws -> SegmentFormat {
        try await start(writingTo: url, options: SystemAudioOptions())
    }
}

extension TrackCapture: SystemAudioCapturing where Producer == SystemAudioProducer {
    func begin(writingTo url: URL) async throws -> CaptureRun {
        try await begin(writingTo: url, options: SystemAudioOptions())
    }

    func restart(
        after event: CaptureRuntimeEvent,
        writingTo nextSegmentURL: URL
    ) async throws -> CaptureRestartResult {
        guard event.retryability == .restartable else { return .stale }
        return try await replace(runID: event.runID, writingTo: nextSegmentURL, options: nil)
    }

    /// Actively proves that this running tap carries output before microphone AEC can erase
    /// that same output from the only other track.
    func verifySignal() async throws -> Bool {
        guard let recorder = currentRecorder else { return false }
        let observation = await recorder.beginSignalObservation(
            above: SystemAudioProbe.signalThreshold)
        do {
            try await SystemAudioProbe.play()
        } catch {
            await recorder.cancelSignalObservation(observation)
            throw error
        }
        return await recorder.waitForSignal(
            observation, timeout: SystemAudioProbe.observationTimeout)
    }
}
