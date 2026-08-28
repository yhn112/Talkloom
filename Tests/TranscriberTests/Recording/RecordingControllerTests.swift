import Foundation
import Testing
import TranscriberCore

@testable import Transcriber

@Suite("Recording controller")
@MainActor
struct RecordingControllerTests {
    actor FakeMicrophone: MicrophoneCapturing {
        let startDelay: Duration
        let restartDelay: Duration
        let shouldFailStart: Bool
        var restartFailuresRemaining: Int
        private(set) var beginCount = 0
        private(set) var endCount = 0
        private(set) var restartCount = 0

        /// Whether echo cancellation was asked for. The controller decides this from an
        /// active system-track probe, and it decides what the microphone track contains,
        /// so it is the part worth pinning down here.
        private(set) var lastVoiceProcessing: Bool?
        private(set) var hasLiveResource = false
        private var currentRun: CaptureRun?
        private var eventHandler: (@Sendable (CaptureRuntimeEvent) -> Void)?
        private var firstSampleHandler: (@Sendable (UInt64) -> Void)?

        init(
            startDelay: Duration = .zero,
            restartDelay: Duration = .zero,
            shouldFailStart: Bool = false,
            restartFailures: Int = 0
        ) {
            self.startDelay = startDelay
            self.restartDelay = restartDelay
            self.shouldFailStart = shouldFailStart
            self.restartFailuresRemaining = restartFailures
        }

        func begin(writingTo url: URL, voiceProcessing: Bool) async throws -> CaptureRun {
            beginCount += 1
            lastVoiceProcessing = voiceProcessing
            if startDelay > .zero { try await Task.sleep(for: startDelay) }
            if shouldFailStart { throw CocoaError(.fileWriteUnknown) }
            // Production publishes its recorder after its final suspension. Installing the
            // marker here reproduces the actor-reentrancy window a premature `end()` misses.
            hasLiveResource = true
            let run = CaptureRun(id: UUID(), segmentIndex: 0)
            currentRun = run
            return run
        }

        func observeRuntimeEvents(
            _ handler: @escaping @Sendable (CaptureRuntimeEvent) -> Void
        ) {
            eventHandler = handler
        }

        func monitorFirstSample(_ handler: @escaping @Sendable (UInt64) -> Void) {
            firstSampleHandler = handler
        }

        func restart(
            after event: CaptureRuntimeEvent,
            writingTo nextSegmentURL: URL
        ) async throws -> CaptureRestartResult {
            guard let currentRun, currentRun.id == event.runID else { return .stale }
            restartCount += 1
            if restartDelay > .zero { try await Task.sleep(for: restartDelay) }
            guard self.currentRun == currentRun else { return .stale }
            if restartFailuresRemaining > 0 {
                restartFailuresRemaining -= 1
                throw CocoaError(.fileReadUnknown)
            }
            let run = CaptureRun(id: UUID(), segmentIndex: currentRun.segmentIndex + 1)
            self.currentRun = run
            return .restarted(run)
        }

        func reconfigure(
            run: CaptureRun,
            writingTo nextSegmentURL: URL,
            voiceProcessing: Bool
        ) async throws -> CaptureRestartResult {
            guard currentRun == run else { return .stale }
            restartCount += 1
            if restartDelay > .zero { try await Task.sleep(for: restartDelay) }
            guard currentRun == run else { return .stale }
            if restartFailuresRemaining > 0 {
                restartFailuresRemaining -= 1
                throw CocoaError(.fileReadUnknown)
            }
            lastVoiceProcessing = voiceProcessing
            let replacement = CaptureRun(id: UUID(), segmentIndex: run.segmentIndex + 1)
            currentRun = replacement
            return .restarted(replacement)
        }

        func finishSession() -> [TrackRecorder.Completion] {
            endCount += 1
            eventHandler = nil
            firstSampleHandler = nil
            currentRun = nil
            hasLiveResource = false
            return []
        }

        func fail(
            _ message: String,
            retryability: CaptureRuntimeEvent.Retryability = .restartable
        ) {
            guard let currentRun else { return }
            eventHandler?(
                CaptureRuntimeEvent(
                    runID: currentRun.id,
                    message: message,
                    retryability: retryability))
        }

        func reportFirstSample(_ hostTime: UInt64) { firstSampleHandler?(hostTime) }
    }

    actor FakeSystemAudio: SystemAudioCapturing {
        let startDelay: Duration
        let restartDelay: Duration
        let endDelay: Duration
        let completion: TrackRecorder.Completion?
        let restartCompletion: TrackRecorder.Completion?
        let shouldFailStart: Bool
        let verifiedSignal: Bool
        let restartVerifiedSignal: Bool?
        let shouldFailVerification: Bool
        var restartFailuresRemaining: Int
        private(set) var beginCount = 0
        private(set) var endCount = 0
        private(set) var restartCount = 0
        private(set) var verificationCount = 0
        private var currentRun: CaptureRun?
        private var eventHandler: (@Sendable (CaptureRuntimeEvent) -> Void)?
        private var retiredEventHandler: (@Sendable (CaptureRuntimeEvent) -> Void)?
        private var retiredEvent: CaptureRuntimeEvent?
        private var firstSampleHandler: (@Sendable (UInt64) -> Void)?
        private var didStoreRestartCompletion = false

        init(
            startDelay: Duration = .zero,
            restartDelay: Duration = .zero,
            endDelay: Duration = .zero,
            completion: TrackRecorder.Completion? = nil,
            restartCompletion: TrackRecorder.Completion? = nil,
            shouldFailStart: Bool = false,
            verifiedSignal: Bool = true,
            restartVerifiedSignal: Bool? = nil,
            restartFailures: Int = 0,
            shouldFailVerification: Bool = false
        ) {
            self.startDelay = startDelay
            self.restartDelay = restartDelay
            self.endDelay = endDelay
            self.completion = completion
            self.restartCompletion = restartCompletion
            self.shouldFailStart = shouldFailStart
            self.verifiedSignal = verifiedSignal
            self.restartVerifiedSignal = restartVerifiedSignal
            self.restartFailuresRemaining = restartFailures
            self.shouldFailVerification = shouldFailVerification
        }

        func begin(writingTo url: URL) async throws -> CaptureRun {
            beginCount += 1
            if startDelay > .zero { try await Task.sleep(for: startDelay) }
            if shouldFailStart { throw CocoaError(.fileWriteUnknown) }
            let run = CaptureRun(id: UUID(), segmentIndex: 0)
            currentRun = run
            return run
        }

        func observeRuntimeEvents(
            _ handler: @escaping @Sendable (CaptureRuntimeEvent) -> Void
        ) {
            eventHandler = handler
        }

        func verifySignal() throws -> Bool {
            if shouldFailVerification { throw CocoaError(.fileReadUnknown) }
            verificationCount += 1
            if verificationCount > 1, let restartVerifiedSignal { return restartVerifiedSignal }
            return verifiedSignal
        }

        func monitorFirstSample(_ handler: @escaping @Sendable (UInt64) -> Void) {
            firstSampleHandler = handler
        }

        func restart(
            after event: CaptureRuntimeEvent,
            writingTo nextSegmentURL: URL
        ) async throws -> CaptureRestartResult {
            guard let currentRun, currentRun.id == event.runID else { return .stale }
            restartCount += 1
            if restartCompletion != nil { didStoreRestartCompletion = true }
            if restartDelay > .zero { try await Task.sleep(for: restartDelay) }
            guard self.currentRun == currentRun else { return .stale }
            if restartFailuresRemaining > 0 {
                restartFailuresRemaining -= 1
                throw CocoaError(.fileReadUnknown)
            }
            let run = CaptureRun(id: UUID(), segmentIndex: currentRun.segmentIndex + 1)
            self.currentRun = run
            return .restarted(run)
        }

        func finishSession() async -> [TrackRecorder.Completion] {
            endCount += 1
            if endDelay > .zero { try? await Task.sleep(for: endDelay) }
            if let currentRun {
                retiredEvent = CaptureRuntimeEvent(
                    runID: currentRun.id,
                    message: "retired run",
                    retryability: .restartable)
            }
            retiredEventHandler = eventHandler
            eventHandler = nil
            firstSampleHandler = nil
            currentRun = nil
            return [didStoreRestartCompletion ? restartCompletion : nil, completion].compactMap {
                $0
            }
        }

        func fail(
            _ message: String,
            retryability: CaptureRuntimeEvent.Retryability = .restartable
        ) {
            guard let currentRun else { return }
            eventHandler?(
                CaptureRuntimeEvent(
                    runID: currentRun.id,
                    message: message,
                    retryability: retryability))
        }

        func failRetiredSession(_ message: String) {
            guard let retiredEvent else { return }
            retiredEventHandler?(
                CaptureRuntimeEvent(
                    runID: retiredEvent.runID,
                    message: message,
                    retryability: .restartable))
        }
        func reportFirstSample(_ hostTime: UInt64) { firstSampleHandler?(hostTime) }
        var isMonitoringFirstSample: Bool { firstSampleHandler != nil }
    }

    func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "RecordingControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func systemCompletion(
        at url: URL,
        segmentIndex: Int = 0,
        sampleRate: Double = 48_000,
        frameCount: Int = 48_000,
        peakAmplitude: Float = 0.25,
        firstSampleHostTime: UInt64 = 1_000,
        spans: [TrackReport.Span]? = nil,
        failure: TrackRecorder.Failure? = nil
    ) -> TrackRecorder.Completion {
        TrackRecorder.Completion(
            summary: TrackRecorder.Summary(
                label: "system",
                url: url,
                source: .systemAudio,
                segmentIndex: segmentIndex,
                content: .remote,
                sampleRate: sampleRate,
                frameCount: frameCount,
                peakAmplitude: peakAmplitude,
                droppedSampleCount: 0,
                firstSampleHostTime: firstSampleHostTime,
                spans: spans
                    ?? [
                        TrackReport.Span(
                            fileFrameOffset: 0,
                            frameCount: frameCount,
                            startHostTime: firstSampleHostTime
                        )
                    ]
            ),
            failure: failure
        )
    }

    /// The manifest as it was actually written to disk — the version that outlives the app.
    func manifest(in session: RecordingSession) throws -> RecordingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(
            contentsOf: session.directory.appending(path: RecordingManifest.fileName))
        return try decoder.decode(RecordingManifest.self, from: data)
    }

    /// A session directory in the shape a killed process leaves: an in-progress manifest,
    /// and a track whose header still declares zero bytes.
    @discardableResult
    func interruptedSession(_ name: String, in root: URL) throws -> URL {
        let directory = root.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RecordingManifest.recording(startedAt: Date(timeIntervalSince1970: 1_000))
            .write(to: directory)

        let url = directory.appending(path: "mic.wav")
        let writer = try WAVWriter(url: url, sampleRate: 48_000, channelCount: 1)
        try [Int16](repeating: 4_096, count: 1_000).withUnsafeBufferPointer {
            try writer.append($0)
        }
        try writer.finish()
        var bytes = try Data(contentsOf: url)
        bytes.replaceSubrange(4..<8, with: Data(repeating: 0, count: 4))
        bytes.replaceSubrange(40..<44, with: Data(repeating: 0, count: 4))
        try bytes.write(to: url)
        return directory
    }
}
