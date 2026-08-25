import Foundation
import Testing
import TranscriberCore

@testable import Transcriber

@Suite("Recording controller")
@MainActor
struct RecordingControllerTests {
    private actor FakeMicrophone: MicrophoneCapturing {
        let startDelay: Duration
        let shouldFailStart: Bool
        private(set) var beginCount = 0
        private(set) var endCount = 0

        /// Whether echo cancellation was asked for. The controller decides this from an
        /// active system-track probe, and it decides what the microphone track contains,
        /// so it is the part worth pinning down here.
        private(set) var lastVoiceProcessing: Bool?
        private(set) var hasLiveResource = false
        private var failureHandler: (@Sendable (String) -> Void)?
        private var firstSampleHandler: (@Sendable (UInt64) -> Void)?

        init(startDelay: Duration = .zero, shouldFailStart: Bool = false) {
            self.startDelay = startDelay
            self.shouldFailStart = shouldFailStart
        }

        func begin(writingTo url: URL, voiceProcessing: Bool) async throws {
            beginCount += 1
            lastVoiceProcessing = voiceProcessing
            if startDelay > .zero { try await Task.sleep(for: startDelay) }
            if shouldFailStart { throw CocoaError(.fileWriteUnknown) }
            // Production publishes its recorder after its final suspension. Installing the
            // marker here reproduces the actor-reentrancy window a premature `end()` misses.
            hasLiveResource = true
        }

        func monitorRuntimeFailures(_ handler: @escaping @Sendable (String) -> Void) {
            failureHandler = handler
        }

        func monitorFirstSample(_ handler: @escaping @Sendable (UInt64) -> Void) {
            firstSampleHandler = handler
        }

        func end() -> TrackRecorder.Completion? {
            endCount += 1
            failureHandler = nil
            firstSampleHandler = nil
            hasLiveResource = false
            return nil
        }

        func reportFirstSample(_ hostTime: UInt64) { firstSampleHandler?(hostTime) }
    }

    private actor FakeSystemAudio: SystemAudioCapturing {
        let startDelay: Duration
        let endDelay: Duration
        let completion: TrackRecorder.Completion?
        let shouldFailStart: Bool
        let verifiedSignal: Bool
        let shouldFailVerification: Bool
        private(set) var beginCount = 0
        private(set) var endCount = 0
        private var failureHandler: (@Sendable (String) -> Void)?
        private var firstSampleHandler: (@Sendable (UInt64) -> Void)?

        init(
            startDelay: Duration = .zero,
            endDelay: Duration = .zero,
            completion: TrackRecorder.Completion? = nil,
            shouldFailStart: Bool = false,
            verifiedSignal: Bool = true,
            shouldFailVerification: Bool = false
        ) {
            self.startDelay = startDelay
            self.endDelay = endDelay
            self.completion = completion
            self.shouldFailStart = shouldFailStart
            self.verifiedSignal = verifiedSignal
            self.shouldFailVerification = shouldFailVerification
        }

        func begin(writingTo url: URL) async throws {
            beginCount += 1
            if startDelay > .zero { try await Task.sleep(for: startDelay) }
            if shouldFailStart { throw CocoaError(.fileWriteUnknown) }
        }

        func monitorRuntimeFailures(_ handler: @escaping @Sendable (String) -> Void) {
            failureHandler = handler
        }

        func verifySignal() throws -> Bool {
            if shouldFailVerification { throw CocoaError(.fileReadUnknown) }
            return verifiedSignal
        }

        func monitorFirstSample(_ handler: @escaping @Sendable (UInt64) -> Void) {
            firstSampleHandler = handler
        }

        func end() async -> TrackRecorder.Completion? {
            endCount += 1
            if endDelay > .zero { try? await Task.sleep(for: endDelay) }
            failureHandler = nil
            firstSampleHandler = nil
            return completion
        }

        func fail(_ message: String) { failureHandler?(message) }
        func reportFirstSample(_ hostTime: UInt64) { firstSampleHandler?(hostTime) }
        var isMonitoringFirstSample: Bool { firstSampleHandler != nil }
    }

    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "RecordingControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func systemCompletion(
        at url: URL,
        frameCount: Int = 48_000,
        peakAmplitude: Float = 0.25,
        failure: TrackRecorder.Failure? = nil
    ) -> TrackRecorder.Completion {
        TrackRecorder.Completion(
            summary: TrackRecorder.Summary(
                label: "system",
                url: url,
                content: .remote,
                sampleRate: 48_000,
                frameCount: frameCount,
                peakAmplitude: peakAmplitude,
                droppedSampleCount: 0,
                firstSampleHostTime: 1_000,
                spans: [
                    TrackReport.Span(
                        fileFrameOffset: 0,
                        frameCount: frameCount,
                        startHostTime: 1_000
                    )
                ]
            ),
            failure: failure
        )
    }

    /// The manifest as it was actually written to disk — the version that outlives the app.
    private func manifest(in session: RecordingSession) throws -> RecordingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(
            contentsOf: session.directory.appending(path: RecordingManifest.fileName))
        return try decoder.decode(RecordingManifest.self, from: data)
    }

    /// A session directory in the shape a killed process leaves: an in-progress manifest,
    /// and a track whose header still declares zero bytes.
    @discardableResult
    private func interruptedSession(_ name: String, in root: URL) throws -> URL {
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

    /// The wiring, not the repair — what recovery does to a directory belongs to the
    /// package tests. What matters here is that it happens, and that it happens once: it
    /// describes the previous run, and re-running it over this run's sessions would be a
    /// second app deciding what a live recording is.
    @Test("recordings a previous run never finished are repaired once")
    func interruptedSessionsAreRepairedOnce() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try interruptedSession("2026-01-01_10-00-00", in: root)
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: FakeMicrophone(),
            systemAudio: FakeSystemAudio()
        )

        await controller.recoverInterruptedSessions()

        #expect(controller.recoveredSessions.count == 1)
        #expect(controller.recoveredSessions.first?.repairedTracks == ["mic.wav"])
        #expect(controller.recoveredSessions.first?.failure == nil)

        try interruptedSession("2026-01-02_10-00-00", in: root)
        await controller.recoverInterruptedSessions()

        #expect(
            controller.recoveredSessions.map(\.directory.lastPathComponent)
                == ["2026-01-01_10-00-00"])
    }

    @Test("a microphone start failure rolls back system capture")
    func microphoneStartFailureRollsBackSystemCapture() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let system = FakeSystemAudio()
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: FakeMicrophone(shouldFailStart: true),
            systemAudio: system
        )

        await controller.start()

        #expect(controller.errorMessage != nil)
        #expect(await system.beginCount == 1)
        #expect(await system.endCount == 1)
        #expect(controller.currentSession == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [])
    }

    @Test("a second start during startup is ignored")
    func secondStartDuringStartupIsIgnored() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone(startDelay: .milliseconds(100))
        let system = FakeSystemAudio(startDelay: .milliseconds(100))
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: microphone,
            systemAudio: system
        )

        let firstStart = Task { await controller.start() }
        await Task.yield()
        await controller.start()
        await firstStart.value

        #expect(await system.beginCount == 1)
        #expect(await microphone.beginCount == 1)
        #expect(controller.isRecording)
        await controller.stop()
    }

    @Test("a runtime failure stops both tracks and fails the session")
    func runtimeFailureStopsBothTracksAndFailsTheSession() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone()
        let system = FakeSystemAudio()
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: microphone,
            systemAudio: system
        )
        await controller.start()
        let session = try #require(controller.currentSession)

        await system.fail("device disappeared")
        for _ in 0..<20 where controller.errorMessage == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(controller.errorMessage == "System audio capture stopped: device disappeared")
        #expect(await microphone.endCount == 1)
        #expect(await system.endCount == 1)
        #expect(try manifest(in: session).failure == controller.errorMessage)
    }

    /// This is inspected before stop: the final manifest already carried the offsets. The
    /// regression is specifically whether a kill during capture loses the only alignment.
    @Test("first samples reach the in-progress manifest")
    func firstSamplesReachTheInProgressManifest() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone(startDelay: .milliseconds(100))
        let system = FakeSystemAudio()
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: microphone,
            systemAudio: system
        )
        let start = Task { await controller.start() }
        for _ in 0..<100 where !(await system.isMonitoringFirstSample) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await system.isMonitoringFirstSample)
        let session = try #require(controller.currentSession)

        await system.reportFirstSample(1_000)
        for _ in 0..<20 where (try? manifest(in: session).trackStarts.count) != 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            try manifest(in: session).trackStarts == [
                .init(file: "system.wav", hostTime: 1_000)
            ],
            "system time is durable while microphone startup is still suspended")

        await start.value
        await microphone.reportFirstSample(2_000)
        for _ in 0..<20 where (try? manifest(in: session).trackStarts.count) != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let inProgress = try manifest(in: session)
        #expect(inProgress.status == .recording)
        #expect(
            inProgress.trackStarts == [
                .init(file: "mic.wav", hostTime: 2_000),
                .init(file: "system.wav", hostTime: 1_000),
            ])
        await controller.stop()
    }

    @Test("a checkpoint failure stops the session")
    func checkpointFailureStopsTheSession() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone(startDelay: .milliseconds(100))
        let system = FakeSystemAudio()
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: microphone,
            systemAudio: system
        )
        let start = Task { await controller.start() }
        for _ in 0..<100 where !(await system.isMonitoringFirstSample) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await system.isMonitoringFirstSample)
        let session = try #require(controller.currentSession)
        let path = session.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }

        await system.reportFirstSample(1_000)
        for _ in 0..<20 where controller.errorMessage == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        await start.value

        #expect(controller.errorMessage?.contains("timeline could not be checkpointed") == true)
        #expect(await microphone.endCount == 1)
        #expect(await !microphone.hasLiveResource)
        #expect(await system.endCount == 1)
    }

    @Test("a start during stop is ignored")
    func startDuringStopIsIgnored() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone()
        let system = FakeSystemAudio(endDelay: .milliseconds(100))
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: microphone,
            systemAudio: system
        )
        await controller.start()

        let stop = Task { await controller.stop() }
        while !controller.isTransitioning { await Task.yield() }
        await controller.start()
        await stop.value

        #expect(await microphone.beginCount == 1)
        #expect(await system.beginCount == 1)
        #expect(!controller.isRecording)
        #expect(controller.errorMessage == nil)
    }

    @Test("a track write failure fails the session and persists the partial track")
    func trackWriteFailureFailsSessionAndPersistsPartialTrack() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let system = FakeSystemAudio(
            completion: systemCompletion(
                at: root.appending(path: "partial-system.wav"),
                frameCount: 24_000,
                peakAmplitude: 0.5,
                failure: .writeFailed(label: "system", reason: "disk full")
            )
        )
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: FakeMicrophone(),
            systemAudio: system
        )
        await controller.start()
        let session = try #require(controller.currentSession)

        await controller.stop()

        #expect(controller.errorMessage == "The system track could not write audio: disk full")
        #expect(controller.lastSystemTrack?.frameCount == 24_000)
        let written = try manifest(in: session)
        #expect(written.failure == controller.errorMessage)
        #expect(written.tracks.first?.failure == controller.errorMessage)
    }

    /// The tracks are finalized on disk while the only description of them still says
    /// `recording` and carries no timestamps. Reporting that as a clean stop would leave the
    /// user with a session nothing downstream can read, and no reason to look.
    @Test("a session whose manifest cannot be replaced does not stop successfully")
    func aSessionWhoseManifestCannotBeReplacedFails() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: FakeMicrophone(),
            systemAudio: FakeSystemAudio()
        )
        await controller.start()
        let session = try #require(controller.currentSession)

        // A read-only directory is the cheapest reproduction: the manifest is replaced
        // atomically, so the temporary file it writes alongside cannot be created either.
        let path = session.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }

        await controller.stop()

        let message = try #require(controller.errorMessage)
        #expect(message.contains("could not be described on disk"))
        #expect(message.contains(session.directory.lastPathComponent))
        // What survived on disk is the in-progress manifest, which is what a recovery pass
        // has to find: `completed` would have been a lie, and nothing at all would look
        // like a directory that was never a session.
        #expect(try manifest(in: session).status == .recording)
    }

    /// When the tap does not come up, the session continues on the microphone alone with
    /// echo cancellation off — which means that recording holds both sides of the call. The
    /// menu bar says so while the app is open; the manifest has to say so for good, because
    /// it is what the transcription step will read months later.
    @Test("a fallback to the microphone alone is recorded in the manifest")
    func fallbackToTheMicrophoneAloneIsRecordedInTheManifest() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone()
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: microphone,
            systemAudio: FakeSystemAudio(shouldFailStart: true)
        )

        await controller.start()
        let session = try #require(controller.currentSession)
        await controller.stop()

        #expect(
            await microphone.lastVoiceProcessing == false,
            "the remote side is only on the mic track now")
        #expect(controller.errorMessage == nil, "a degraded recording is not a failed one")

        let written = try manifest(in: session)
        #expect(written.status == .completed)
        #expect(written.warning == controller.warning)
        #expect(written.warning != nil)
    }

    @Test("a session that used both paths carries no warning")
    func aSessionThatUsedBothPathsCarriesNoWarning() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone()
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: microphone,
            systemAudio: FakeSystemAudio(
                completion: systemCompletion(at: root.appending(path: "system.wav"))
            )
        )

        await controller.start()
        let session = try #require(controller.currentSession)
        await controller.stop()

        #expect(await microphone.lastVoiceProcessing == true)

        let written = try manifest(in: session)
        #expect(written.warning == nil)
        #expect(written.tracks.first?.content == .remote)
    }

    @Test("a silent verification probe preserves remote audio in the microphone track")
    func silentVerificationProbePreservesRemoteAudioInMicrophoneTrack() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone()
        let system = FakeSystemAudio(
            completion: systemCompletion(at: root.appending(path: "system.wav")),
            verifiedSignal: false
        )
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: microphone,
            systemAudio: system
        )

        await controller.start()
        let session = try #require(controller.currentSession)
        #expect(await microphone.lastVoiceProcessing == false)
        #expect(controller.warning != nil)

        await controller.stop()
        #expect(await system.endCount == 1, "an unverified system path is still finalized")
        let written = try manifest(in: session)
        #expect(written.warning == controller.warning)
    }

    @Test("a failed verification probe preserves remote audio in the microphone track")
    func failedVerificationProbePreservesRemoteAudioInMicrophoneTrack() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone()
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: microphone,
            systemAudio: FakeSystemAudio(shouldFailVerification: true)
        )

        await controller.start()

        #expect(await microphone.lastVoiceProcessing == false)
        #expect(
            controller.isRecording, "probe failure degrades the recording instead of aborting it")
        #expect(controller.warning?.contains("could not be verified") == true)
        await controller.stop()
    }

    @Test("the active probe marks system audio working before microphone AEC starts")
    func activeProbeMarksSystemAudioWorkingBeforeMicrophoneAECStarts() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let permissions = PermissionManager(microphone: .granted, systemAudio: .granted)
        let microphone = FakeMicrophone()
        let controller = RecordingController(
            permissions: permissions,
            sessionRoot: root,
            microphone: microphone,
            systemAudio: FakeSystemAudio(
                completion: systemCompletion(at: root.appending(path: "system.wav"))
            )
        )

        await controller.start()
        #expect(permissions.systemAudio == .granted)
        #expect(await microphone.lastVoiceProcessing == true)

        await controller.stop()
        #expect(permissions.systemAudio == .granted)
    }

    @Test("silent system audio does not pretend to prove permission")
    func silentSystemAudioDoesNotPretendToProvePermission() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let permissions = PermissionManager(microphone: .granted)
        let controller = RecordingController(
            permissions: permissions,
            sessionRoot: root,
            microphone: FakeMicrophone(),
            systemAudio: FakeSystemAudio(
                completion: systemCompletion(
                    at: root.appending(path: "system.wav"),
                    peakAmplitude: 0
                ),
                verifiedSignal: false
            )
        )

        await controller.start()
        await controller.stop()

        #expect(permissions.systemAudio == .notDetermined)
    }
}
