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
        case tapCreationFailed(OSStatus)
        case tapFormatUnavailable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case unusableTapFormat(sampleRate: Double, channelCount: UInt32)

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let status):
                "Could not tap the system audio (\(Self.describe(status))). Grant Transcriber access under System Settings › Privacy & Security › Audio Recording."
            case .tapFormatUnavailable(let status):
                "The system audio tap did not report its format (\(Self.describe(status)))."
            case .aggregateCreationFailed(let status):
                "Could not create the aggregate device for the system audio tap (\(Self.describe(status)))."
            case .ioProcCreationFailed(let status):
                "Could not attach to the system audio tap (\(Self.describe(status)))."
            case .deviceStartFailed(let status):
                "Could not start the system audio tap (\(Self.describe(status)))."
            case .unusableTapFormat(let sampleRate, let channelCount):
                "The system audio tap reported an unusable format (\(sampleRate) Hz, \(channelCount) channels)."
            }
        }

        /// OSStatus values in this API are four-character codes far more often than numbers.
        private static func describe(_ status: OSStatus) -> String {
            let bytes = [24, 16, 8, 0].map { UInt8((UInt32(bitPattern: status) >> UInt32($0)) & 0xFF) }
            guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return "status \(status)" }
            return "'\(String(decoding: bytes, as: UTF8.self))'"
        }
    }

    /// One live tap: the objects that have to be torn down together, in this order.
    private struct Tap {
        var tapID: AudioObjectID
        var aggregateID: AudioObjectID
        var ioProcID: AudioDeviceIOProcID?
        var format: AudioStreamBasicDescription
    }

    /// The IO block is dispatched onto this queue. The header is explicit that IO blocks
    /// are dispatched *synchronously*, so this is still a real-time context — the queue
    /// buys nothing that would make allocating or locking acceptable.
    private let ioQueue = DispatchQueue(label: "me.diskin.Transcriber.system-audio", qos: .userInitiated)

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
            AppLog.capture.error("the system audio tap was dropped without being stopped; tearing it down")
            if let ioProcID = tap.ioProcID {
                AudioDeviceStop(tap.aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(tap.aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(tap.aggregateID)
            AudioHardwareDestroyProcessTap(tap.tapID)
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
            destroy(probe)
            throw Failure.unusableTapFormat(
                sampleRate: sampleRate,
                channelCount: probe.format.mChannelsPerFrame
            )
        }

        let recorder = try TrackRecorder(label: "system", url: url, sampleRate: sampleRate)
        do {
            var running = probe
            try attachAndStart(&running, feeding: recorder.input)
            self.tap = running
        } catch {
            destroy(probe)
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

    /// Arms the watchdog once the controller is ready to stop the complete session.
    func monitorRuntimeFailures(_ handler: @escaping @Sendable (String) -> Void) {
        guard recorder != nil else { return }
        runtimeFailureHandler = handler
        startWatchdog()
    }

    /// Stops capture and closes the file.
    func stop() async -> TrackRecorder.Summary? {
        guard let recorder else { return nil }
        self.recorder = nil
        runtimeFailureHandler = nil

        watchdogTask?.cancel()
        watchdogTask = nil
        if let tap {
            destroy(tap)
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
        let summary = await recorder.finish()
        AppLog.capture.notice(
            "system audio track: \(summary.duration, format: .fixed(precision: 1), privacy: .public) s, peak \(summary.peakAmplitude, format: .fixed(precision: 4), privacy: .public), dropped \(summary.droppedSampleCount, privacy: .public) samples"
        )
        if summary.isSilent {
            AppLog.capture.error(
                "system audio track is silent; nothing was playing, or the Audio Recording permission is missing"
            )
        }
        return summary
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

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw Failure.tapCreationFailed(tapStatus)
        }

        do {
            // Read the format the tap actually reports rather than assuming one. Assuming
            // here is what produces a valid file full of silence.
            let format = try readTapFormat(tapID)
            let aggregateID = try createAggregate(around: description.uuid.uuidString)
            return Tap(tapID: tapID, aggregateID: aggregateID, ioProcID: nil, format: format)
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    private func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw Failure.tapFormatUnavailable(status) }
        return format
    }

    private func createAggregate(around tapUID: String) throws -> AudioObjectID {
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

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            throw Failure.aggregateCreationFailed(status)
        }
        return aggregateID
    }

    private func attachAndStart(_ tap: inout Tap, feeding trackInput: TrackInput) throws {
        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, tap.aggregateID, ioQueue) {
            _, inputData, inputTime, _, _ in
            // Real-time context: a timestamp store and a copy into a preallocated ring
            // buffer, nothing else.
            if inputTime.pointee.mFlags.contains(.hostTimeValid) {
                trackInput.noteFirstHostTime(inputTime.pointee.mHostTime)
            }
            trackInput.write(inputData)
        }
        guard createStatus == noErr, let ioProcID else {
            throw Failure.ioProcCreationFailed(createStatus)
        }
        tap.ioProcID = ioProcID

        let startStatus = AudioDeviceStart(tap.aggregateID, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(tap.aggregateID, ioProcID)
            tap.ioProcID = nil
            throw Failure.deviceStartFailed(startStatus)
        }
    }

    /// Tears a tap down in the order the objects depend on each other. An aggregate device
    /// that is never destroyed outlives the process.
    private func destroy(_ tap: Tap) {
        if let ioProcID = tap.ioProcID {
            AudioDeviceStop(tap.aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(tap.aggregateID, ioProcID)
        }
        AudioHardwareDestroyAggregateDevice(tap.aggregateID)
        AudioHardwareDestroyProcessTap(tap.tapID)
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
