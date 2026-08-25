import AVFoundation
import Foundation
import TranscriberCore

/// Two stable engine graphs for the two microphone modes.
///
/// AVFAudio delivers Voice Processing IO property notifications on an internal queue and
/// provides no teardown-completion API. A segment therefore borrows one of these engines;
/// destroying the segment must not destroy the engine while a property listener may still
/// be running. `MicrophoneProducer` is process-long-lived and retains this set across every
/// segment and session.
final class MicrophoneEngineSet {
    private let voiceProcessingEngine = AVAudioEngine()
    private let rawEngine = AVAudioEngine()

    func engine(voiceProcessing: Bool) -> AVAudioEngine {
        voiceProcessing ? voiceProcessingEngine : rawEngine
    }
}

/// How a microphone generation is configured.
///
/// Echo cancellation travels with the generation because a restart has to reproduce it: a
/// replacement that quietly came up in the other mode would change what the master contains
/// halfway through a meeting, and the manifest would still describe the first mode.
struct MicrophoneOptions: Sendable {
    let voiceProcessing: Bool
    let ducking: AVAudioVoiceProcessingOtherAudioDuckingConfiguration

    init(
        voiceProcessing: Bool,
        ducking: AVAudioVoiceProcessingOtherAudioDuckingConfiguration = MicrophoneProducer
            .transparentDucking
    ) {
        self.voiceProcessing = voiceProcessing
        self.ducking = ducking
    }
}

/// Produces microphone generations through Voice Processing IO.
///
/// Echo cancellation is not a refinement here, it is the reason this path exists. Without
/// it the microphone picks up the other participants coming back out of the speakers,
/// Whisper transcribes them from the microphone track too, and every remote line lands in
/// the transcript twice — the second time attributed to "me". Headphones would solve it;
/// the app cannot assume them.
final class MicrophoneProducer: SegmentProducer {
    /// Frames requested per tap callback. The node is free to deliver a different size, so
    /// nothing downstream may assume it.
    private static let tapBufferSize: AVAudioFrameCount = 4_096

    /// The engine a generation borrows, and the format it was configured at.
    ///
    /// The format is read once, after voice processing is enabled, and then carried: the
    /// node reports a different one before and after, and a tap installed at the earlier
    /// format records silence without reporting an error.
    final class Generation {
        let engine: AVAudioEngine
        let format: AVAudioFormat
        let voiceProcessing: Bool

        init(engine: AVAudioEngine, format: AVAudioFormat, voiceProcessing: Bool) {
            self.engine = engine
            self.format = format
            self.voiceProcessing = voiceProcessing
        }
    }

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

    private let engines = MicrophoneEngineSet()
    private var didEnableVoiceProcessing = false
    private var configurationObserver: (any NSObjectProtocol)?

    /// Generations handed out and not yet released. `release` quiets them; this list exists
    /// so that a producer dropped with one still running can say so, which is the only thing
    /// it is safe to do about it at that point.
    private var outstanding: [Generation] = []

    let descriptor = CaptureTrackDescriptor(
        trackLabel: "mic",
        name: "microphone",
        source: .microphone
    )

    init() {}

    /// Deliberately does not stop the engines.
    ///
    /// This runs on whatever thread drops the last reference, and reconfiguring Voice
    /// Processing IO while everything around it is being torn down is the neighbourhood of the
    /// reproducible `AVAudioIOUnit::IOUnitPropertyListener` crash `acquire` documents. The
    /// resource that must not outlive the process is the aggregate device, and that belongs to
    /// CoreAudio. The engines are deallocated together with this producer whichever way it goes
    /// — in the app it is process-lifetime, and in a device test the `MicrophoneEngineSet` goes
    /// with it — so stopping them first buys nothing and only adds calls next to a known crash.
    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        if !outstanding.isEmpty {
            AppLog.capture.error(
                "the microphone was dropped without being stopped; its engine is left to the process"
            )
        }
    }

    /// Echo cancellation is what makes this track "me" rather than "the room". Without it
    /// the speakers are in here too, and the manifest has to say so.
    func content(for options: MicrophoneOptions) -> TrackContent {
        options.voiceProcessing ? .local : .mixed
    }

    func acquire(_ options: MicrophoneOptions) throws -> (Generation, SegmentFormat) {
        let engine = engines.engine(voiceProcessing: options.voiceProcessing)
        let input = engine.inputNode

        if options.voiceProcessing {
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
            input.voiceProcessingOtherAudioDuckingConfiguration = options.ducking
            let applied = input.voiceProcessingOtherAudioDuckingConfiguration
            AppLog.capture.debug(
                "ducking requested advanced=\(options.ducking.enableAdvancedDucking.boolValue, privacy: .public) level=\(options.ducking.duckingLevel.rawValue, privacy: .public); node reports advanced=\(applied.enableAdvancedDucking.boolValue, privacy: .public) level=\(applied.duckingLevel.rawValue, privacy: .public)"
            )
        } else {
            // This dedicated graph has never hosted Voice Processing IO. Keeping the modes
            // on separate retained engines avoids toggling the destructive processing unit.
            precondition(!input.isVoiceProcessingEnabled)
        }

        // Read the format *after* enabling voice processing.
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
        if !options.voiceProcessing {
            engine.connect(input, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
        }

        let generation = Generation(
            engine: engine,
            format: format,
            voiceProcessing: options.voiceProcessing
        )
        outstanding.append(generation)
        return (
            generation,
            SegmentFormat(sampleRate: format.sampleRate, channelCount: format.channelCount)
        )
    }

    func attach(_ generation: Generation, to input: TrackInput) throws {
        let node = generation.engine.inputNode
        node.installTap(
            onBus: 0, bufferSize: Self.tapBufferSize, format: generation.format
        ) { buffer, when in
            // Real-time context: one coordinated timestamp/boundary/sample handoff into
            // preallocated SPSC rings, nothing else.
            input.write(buffer, atHostTime: when.isHostTimeValid ? when.hostTime : nil)
        }

        generation.engine.prepare()
        do {
            try generation.engine.start()
        } catch {
            throw Failure.engineFailed(error.localizedDescription)
        }
    }

    /// The engines are never destroyed, only quieted.
    ///
    /// Voice processing is deliberately left enabled too. Turning it off here reconfigures
    /// the audio unit at the exact moment everything around it is being torn down, and
    /// AVFAudio's own property listener then fired against freed memory — a reproducible
    /// SIGSEGV in `AVAudioIOUnit::IOUnitPropertyListener`. A stopped engine captures nothing
    /// either way, so the only thing switching it off achieved was the crash, and leaving it
    /// on makes the next recording start sooner.
    func release(_ generation: Generation, context: String) {
        Self.quiet(generation)
        outstanding.removeAll { $0 === generation }
    }

    private static func quiet(_ generation: Generation) {
        generation.engine.inputNode.removeTap(onBus: 0)
        generation.engine.stop()
    }

    /// Plugging in headphones changes the default device and stops the engine underneath us.
    func beginWatching(
        _ generation: Generation,
        input: TrackInput,
        report: @escaping @Sendable (String, CaptureRuntimeEvent.Retryability) -> Void
    ) {
        stopWatching()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: generation.engine,
            queue: nil
        ) { _ in
            report("The microphone audio configuration changed.", .restartable)
        }
    }

    func stopWatching() {
        guard let configurationObserver else { return }
        NotificationCenter.default.removeObserver(configurationObserver)
        self.configurationObserver = nil
    }

    func logStarted(_ generation: Generation, format: SegmentFormat) {
        let engine = generation.engine
        AppLog.capture.notice(
            "microphone capture started at \(format.sampleRate, format: .fixed(precision: 0), privacy: .public) Hz, \(format.channelCount, privacy: .public) channel(s), voice processing \(engine.inputNode.isVoiceProcessingEnabled ? "on" : "off", privacy: .public); output node expects \(engine.outputNode.inputFormat(forBus: 0).sampleRate, format: .fixed(precision: 0), privacy: .public) Hz, \(engine.outputNode.inputFormat(forBus: 0).channelCount, privacy: .public) channel(s)"
        )
    }

    func logCompleted(_ summary: TrackRecorder.Summary) {
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
}

/// The microphone track: one lifecycle, one producer.
typealias MicrophoneCapture = TrackCapture<MicrophoneProducer>

extension TrackCapture where Producer == MicrophoneProducer {
    /// Starts capture into `url` and reports the format the device actually delivered.
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
        ducking: AVAudioVoiceProcessingOtherAudioDuckingConfiguration = MicrophoneProducer
            .transparentDucking
    ) async throws -> SegmentFormat {
        try await start(
            writingTo: url,
            options: MicrophoneOptions(voiceProcessing: voiceProcessing, ducking: ducking)
        )
    }
}

extension TrackCapture: MicrophoneCapturing where Producer == MicrophoneProducer {
    func begin(writingTo url: URL, voiceProcessing: Bool) async throws -> CaptureRun {
        try await begin(
            writingTo: url,
            options: MicrophoneOptions(voiceProcessing: voiceProcessing)
        )
    }

    /// A restart keeps the failed generation's own configuration; only `reconfigure` changes
    /// it, and only because the system track stopped justifying echo cancellation.
    func restart(
        after event: CaptureRuntimeEvent,
        writingTo nextSegmentURL: URL
    ) async throws -> CaptureRestartResult {
        guard event.retryability == .restartable else { return .stale }
        return try await replace(
            runID: event.runID, writingTo: nextSegmentURL, options: nil)
    }

    func reconfigure(
        run: CaptureRun,
        writingTo nextSegmentURL: URL,
        voiceProcessing: Bool
    ) async throws -> CaptureRestartResult {
        try await replace(
            runID: run.id,
            writingTo: nextSegmentURL,
            options: MicrophoneOptions(voiceProcessing: voiceProcessing)
        )
    }
}
