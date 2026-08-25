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
actor SystemAudioCapture {
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

    private var tap: Tap?
    private var recorder: TrackRecorder?
    private var watchdogTask: Task<Void, Never>?
    private var lastObservedSampleCount = 0
    private var stalledSeconds = 0
    private var runtimeFailureHandler: (@Sendable (String) -> Void)?

    /// Last resort for the tap and its aggregate device.
    ///
    /// `stop()` is the ordinary path and does this properly, flushing the file as well.
    /// This exists because an aggregate device that is never destroyed outlives the process
    /// that made it — it becomes litter in the user's audio system, visible to every other
    /// app, and nothing cleans it up. Dropping this actor without stopping it should not
    /// leave that behind.
    deinit {
        if let tap {
            AppLog.capture.error(
                "the system audio tap was dropped without being stopped; tearing it down")
            Self.destroy(tap, context: "deinit fallback")
        }
        watchdogTask?.cancel()
    }

    /// Starts capture into `url` and returns the sample rate the tap reported.
    @discardableResult
    func start(writingTo url: URL) async throws -> Double {
        guard recorder == nil else { return tap?.format.mSampleRate ?? 0 }

        // The format has to be known before the recorder exists, and only the tap can say
        // what it is — so the tap is built first, against a temporary handle, and the
        // recorder is created from what it reported.
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
                sampleRate: sampleRate,
                content: .remote
            )
        } catch {
            Self.destroy(probe, context: "rolling back track recorder creation")
            throw error
        }
        var running = probe
        do {
            try attachAndStart(&running, feeding: recorder.input)
            self.tap = running
        } catch {
            Self.destroy(running, context: "rolling back a failed system audio start")
            _ = await recorder.finish()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        await recorder.start()
        self.recorder = recorder
        lastObservedSampleCount = 0
        stalledSeconds = 0

        let format = probe.format
        AppLog.capture.notice(
            "system audio tap format: \(format.mSampleRate, format: .fixed(precision: 0), privacy: .public) Hz, \(format.mChannelsPerFrame, privacy: .public) ch, \(format.mBytesPerFrame, privacy: .public) bytes/frame, \(format.mFramesPerPacket, privacy: .public) frames/packet, flags 0x\(String(format.mFormatFlags, radix: 16), privacy: .public)"
        )
        return sampleRate
    }

    /// Arms the watchdog and track monitoring once the controller is ready to stop the
    /// complete session. The watchdog sees a tap that stopped delivering; only the track
    /// itself sees a track that stopped being written.
    func monitorRuntimeFailures(_ handler: @escaping @Sendable (String) -> Void) async {
        guard let recorder else { return }
        runtimeFailureHandler = handler
        startWatchdog()
        await recorder.observeFailures { [weak self] failure in
            Task { await self?.reportRuntimeFailure(failure.localizedDescription) }
        }
    }

    func monitorFirstSample(_ handler: @escaping @Sendable (UInt64) -> Void) async {
        guard let recorder else { return }
        await recorder.observeFirstSample(handler)
    }

    /// Actively proves that this running tap carries output before microphone AEC can erase
    /// that same output from the only other track.
    func verifySignal() async throws -> Bool {
        guard let recorder else { return false }
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

    /// Stops capture and closes the file.
    func stop() async -> TrackRecorder.Completion? {
        guard let recorder else { return nil }
        self.recorder = nil
        runtimeFailureHandler = nil

        watchdogTask?.cancel()
        watchdogTask = nil
        if let tap {
            Self.destroy(tap, context: "stopping system audio capture")
            self.tap = nil
        }

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
        let summary = completion.summary
        AppLog.capture.notice(
            "system audio track: \(summary.duration, format: .fixed(precision: 1), privacy: .public) s, peak \(summary.peakAmplitude, format: .fixed(precision: 4), privacy: .public), dropped \(summary.droppedSampleCount, privacy: .public) samples"
        )
        if summary.isSilent {
            AppLog.capture.error(
                "system audio track is silent; nothing was playing, or the Audio Recording permission is missing"
            )
        }
        return completion
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

    private func startWatchdog() {
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.checkForStall()
            }
        }
    }

    /// Watches the sample count rather than the default output device.
    ///
    /// Changing the output device is the documented way to kill a tap, but it is not the
    /// only one, and listening for it means rebuilding a perfectly healthy tap every time
    /// someone plugs in headphones — a gap in the recording to fix a problem that may not
    /// have happened. A tap that has stopped delivering is the thing that actually matters,
    /// it covers every cause, and nothing else reports it: the file simply goes quiet.
    private func checkForStall() async {
        guard let recorder, tap != nil else { return }

        let refused = recorder.input.unexpectedLayoutCount
        if refused > 0 {
            reportRuntimeFailure(
                "The system audio tap delivered \(refused) unsupported buffer block(s)."
            )
            return
        }

        let received = recorder.input.ring.totalSampleCount
        if received > lastObservedSampleCount {
            lastObservedSampleCount = received
            stalledSeconds = 0
            return
        }

        stalledSeconds += 1
        guard stalledSeconds >= Self.stallTolerance else { return }
        stalledSeconds = 0

        reportRuntimeFailure(
            "The system audio tap stopped delivering samples for \(Self.stallTolerance) seconds."
        )
    }

    private func reportRuntimeFailure(_ message: String) {
        AppLog.capture.error("\(message, privacy: .public)")
        watchdogTask?.cancel()
        watchdogTask = nil
        let handler = runtimeFailureHandler
        runtimeFailureHandler = nil
        handler?(message)
    }
}
