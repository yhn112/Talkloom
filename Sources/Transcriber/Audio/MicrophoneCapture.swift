import AVFoundation
import Foundation

/// Records the microphone through Voice Processing IO.
///
/// Echo cancellation is not a refinement here, it is the reason this path exists. Without
/// it the microphone picks up the other participants coming back out of the speakers,
/// Whisper transcribes them from the microphone track too, and every remote line lands in
/// the transcript twice — the second time attributed to "me". Headphones would solve it;
/// the app cannot assume them.
actor MicrophoneCapture {
    /// Frames requested per tap callback. The node is free to deliver a different size, so
    /// nothing downstream may assume it.
    private static let tapBufferSize: AVAudioFrameCount = 4_096

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

    private let engine = AVAudioEngine()
    private var recorder: TrackRecorder?
    private var configurationObserver: (any NSObjectProtocol)?
    private var runtimeFailureHandler: (@Sendable (String) -> Void)?

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
        guard recorder == nil else { return engine.inputNode.outputFormat(forBus: 0) }
        let input = engine.inputNode

        do {
            // Only settable while the engine is stopped, and it enables voice processing on
            // the output node too — the header is explicit that both sides move together.
            try input.setVoiceProcessingEnabled(voiceProcessing)
        } catch {
            throw Failure.voiceProcessingUnavailable(error.localizedDescription)
        }

        if voiceProcessing {
            input.voiceProcessingOtherAudioDuckingConfiguration = ducking
            let applied = input.voiceProcessingOtherAudioDuckingConfiguration
            AppLog.capture.debug(
                "ducking requested advanced=\(ducking.enableAdvancedDucking.boolValue, privacy: .public) level=\(ducking.duckingLevel.rawValue, privacy: .public); node reports advanced=\(applied.enableAdvancedDucking.boolValue, privacy: .public) level=\(applied.duckingLevel.rawValue, privacy: .public)"
            )
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
            sampleRate: format.sampleRate,
            content: voiceProcessing ? .local : .mixed
        )
        let trackInput = recorder.input
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) { buffer, when in
            // Real-time context: a timestamp store and a copy into a preallocated ring
            // buffer, nothing else.
            if when.isHostTimeValid {
                trackInput.noteFirstHostTime(when.hostTime)
            }
            trackInput.write(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            _ = await recorder.finish()
            try? FileManager.default.removeItem(at: url)
            throw Failure.engineFailed(error.localizedDescription)
        }

        await recorder.start()
        self.recorder = recorder

        AppLog.capture.notice(
            "microphone capture started at \(format.sampleRate, format: .fixed(precision: 0), privacy: .public) Hz, \(format.channelCount, privacy: .public) channel(s), voice processing \(input.isVoiceProcessingEnabled ? "on" : "off", privacy: .public); output node expects \(self.engine.outputNode.inputFormat(forBus: 0).sampleRate, format: .fixed(precision: 0), privacy: .public) Hz, \(self.engine.outputNode.inputFormat(forBus: 0).channelCount, privacy: .public) channel(s)"
        )
        return format
    }

    /// Arms device-change monitoring once the controller is ready to handle a failure.
    func monitorRuntimeFailures(_ handler: @escaping @Sendable (String) -> Void) {
        guard recorder != nil else { return }
        runtimeFailureHandler = handler
        observeConfigurationChanges()
    }

    /// Stops capture and closes the file.
    func stop() async -> TrackRecorder.Completion? {
        guard let recorder else { return nil }
        self.recorder = nil
        runtimeFailureHandler = nil

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }

        // Producer first: anything written after the recorder is finished never reaches disk.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Voice processing is deliberately left enabled. Turning it off here reconfigures
        // the audio unit at the exact moment everything around it is being torn down, and
        // AVFAudio's own property listener then fired against freed memory — a reproducible
        // SIGSEGV in AVAudioIOUnit::IOUnitPropertyListener. A stopped engine captures
        // nothing either way, so the only thing switching it off achieved was the crash,
        // and leaving it on makes the next recording start sooner.

        let completion = await recorder.finish()
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
        return completion
    }

    /// Plugging in headphones changes the default device and stops the engine underneath us.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleConfigurationChange() }
        }
    }

    private func handleConfigurationChange() {
        guard recorder != nil else { return }

        // Even when the sample rate is unchanged, restarting would remove the stopped
        // interval from this WAV and shift its remaining timeline relative to system audio.
        // Until manifests can represent spans, stop both tracks instead.
        reportRuntimeFailure(
            "The microphone audio configuration changed; recording stopped to preserve track alignment."
        )
    }

    private func reportRuntimeFailure(_ message: String) {
        AppLog.capture.error("\(message, privacy: .public)")
        let handler = runtimeFailureHandler
        runtimeFailureHandler = nil
        handler?(message)
    }
}
