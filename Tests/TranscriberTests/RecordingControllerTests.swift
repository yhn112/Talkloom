import TranscriberCore
import XCTest

@testable import Transcriber

@MainActor
final class RecordingControllerTests: XCTestCase {
    private actor FakeMicrophone: MicrophoneCapturing {
        let shouldFailStart: Bool
        private(set) var beginCount = 0
        private(set) var endCount = 0

        /// Whether echo cancellation was asked for. The controller decides this from
        /// whether the system tap came up, and it decides what the microphone track
        /// contains, so it is the part worth pinning down here.
        private(set) var lastVoiceProcessing: Bool?
        private var failureHandler: (@Sendable (String) -> Void)?

        init(shouldFailStart: Bool = false) { self.shouldFailStart = shouldFailStart }

        func begin(writingTo url: URL, voiceProcessing: Bool) async throws {
            beginCount += 1
            lastVoiceProcessing = voiceProcessing
            if shouldFailStart { throw CocoaError(.fileWriteUnknown) }
        }

        func monitorRuntimeFailures(_ handler: @escaping @Sendable (String) -> Void) {
            failureHandler = handler
        }

        func end() -> TrackRecorder.Completion? {
            endCount += 1
            failureHandler = nil
            return nil
        }
    }

    private actor FakeSystemAudio: SystemAudioCapturing {
        let startDelay: Duration
        let endDelay: Duration
        let completion: TrackRecorder.Completion?
        let shouldFailStart: Bool
        private(set) var beginCount = 0
        private(set) var endCount = 0
        private var failureHandler: (@Sendable (String) -> Void)?

        init(
            startDelay: Duration = .zero,
            endDelay: Duration = .zero,
            completion: TrackRecorder.Completion? = nil,
            shouldFailStart: Bool = false
        ) {
            self.startDelay = startDelay
            self.endDelay = endDelay
            self.completion = completion
            self.shouldFailStart = shouldFailStart
        }

        func begin(writingTo url: URL) async throws {
            beginCount += 1
            if startDelay > .zero { try await Task.sleep(for: startDelay) }
            if shouldFailStart { throw CocoaError(.fileWriteUnknown) }
        }

        func monitorRuntimeFailures(_ handler: @escaping @Sendable (String) -> Void) {
            failureHandler = handler
        }

        func end() async -> TrackRecorder.Completion? {
            endCount += 1
            if endDelay > .zero { try? await Task.sleep(for: endDelay) }
            failureHandler = nil
            return completion
        }

        func fail(_ message: String) { failureHandler?(message) }
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
                firstSampleHostTime: 1_000
            ),
            failure: failure
        )
    }

    func testMicrophoneStartFailureRollsBackSystemCapture() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone(shouldFailStart: true)
        let system = FakeSystemAudio()
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: microphone,
            systemAudio: system
        )

        await controller.start()

        let systemBeginCount = await system.beginCount
        let systemEndCount = await system.endCount
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(systemBeginCount, 1)
        XCTAssertEqual(systemEndCount, 1)
        XCTAssertNil(controller.currentSession)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testSecondStartDuringStartupIsIgnored() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone()
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

        let systemBeginCount = await system.beginCount
        let microphoneBeginCount = await microphone.beginCount
        XCTAssertEqual(systemBeginCount, 1)
        XCTAssertEqual(microphoneBeginCount, 1)
        XCTAssertTrue(controller.isRecording)
        await controller.stop()
    }

    func testRuntimeFailureStopsBothTracksAndFailsTheSession() async throws {
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
        let session = try XCTUnwrap(controller.currentSession)

        await system.fail("device disappeared")
        for _ in 0..<20 where controller.errorMessage == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let microphoneEndCount = await microphone.endCount
        let systemEndCount = await system.endCount
        XCTAssertEqual(controller.errorMessage, "System audio capture stopped: device disappeared")
        XCTAssertEqual(microphoneEndCount, 1)
        XCTAssertEqual(systemEndCount, 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(
            contentsOf: session.directory.appending(path: RecordingManifest.fileName))
        let manifest = try decoder.decode(RecordingManifest.self, from: data)
        XCTAssertEqual(manifest.failure, controller.errorMessage)
    }

    func testStartDuringStopIsIgnored() async throws {
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

        let microphoneBeginCount = await microphone.beginCount
        let systemBeginCount = await system.beginCount
        XCTAssertEqual(microphoneBeginCount, 1)
        XCTAssertEqual(systemBeginCount, 1)
        XCTAssertFalse(controller.isRecording)
        XCTAssertNil(controller.errorMessage)
    }

    func testTrackWriteFailureFailsSessionAndPersistsPartialTrack() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let expectedURL = root.appending(path: "partial-system.wav")
        let system = FakeSystemAudio(
            completion: systemCompletion(
                at: expectedURL,
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
        let session = try XCTUnwrap(controller.currentSession)

        await controller.stop()

        XCTAssertEqual(controller.errorMessage, "The system track could not write audio: disk full")
        XCTAssertEqual(controller.lastSystemTrack?.frameCount, 24_000)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(
            contentsOf: session.directory.appending(path: RecordingManifest.fileName))
        let manifest = try decoder.decode(RecordingManifest.self, from: data)
        XCTAssertEqual(manifest.failure, controller.errorMessage)
        XCTAssertEqual(manifest.tracks.first?.failure, controller.errorMessage)
    }

    /// When the tap does not come up, the session continues on the microphone alone with
    /// echo cancellation off — which means that recording holds both sides of the call. The
    /// menu bar says so while the app is open; the manifest has to say so for good, because
    /// it is what the transcription step will read months later.
    func testAFallbackToTheMicrophoneAloneIsRecordedInTheManifest() async throws {
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
        let session = try XCTUnwrap(controller.currentSession)
        await controller.stop()

        let voiceProcessing = await microphone.lastVoiceProcessing
        XCTAssertEqual(voiceProcessing, false, "the remote side is only on the mic track now")
        XCTAssertNil(controller.errorMessage, "a degraded recording is not a failed one")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(
            contentsOf: session.directory.appending(path: RecordingManifest.fileName))
        let manifest = try decoder.decode(RecordingManifest.self, from: data)
        XCTAssertEqual(manifest.status, .completed)
        XCTAssertEqual(manifest.warning, controller.warning)
        XCTAssertNotNil(manifest.warning)
    }

    func testASessionThatUsedBothPathsCarriesNoWarning() async throws {
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
        let session = try XCTUnwrap(controller.currentSession)
        await controller.stop()

        let voiceProcessing = await microphone.lastVoiceProcessing
        XCTAssertEqual(voiceProcessing, true)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(
            contentsOf: session.directory.appending(path: RecordingManifest.fileName))
        let manifest = try decoder.decode(RecordingManifest.self, from: data)
        XCTAssertNil(manifest.warning)
        XCTAssertEqual(manifest.tracks.first?.content, .remote)
    }

    func testSystemAudioIsMarkedWorkingOnlyAfterRecordingSignal() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let permissions = PermissionManager(microphone: .granted, systemAudio: .granted)
        let system = FakeSystemAudio(
            completion: systemCompletion(at: root.appending(path: "system.wav"))
        )
        let controller = RecordingController(
            permissions: permissions,
            sessionRoot: root,
            microphone: FakeMicrophone(),
            systemAudio: system
        )

        await controller.start()
        XCTAssertEqual(permissions.systemAudio, .notDetermined)

        await controller.stop()
        XCTAssertEqual(permissions.systemAudio, .granted)
    }

    func testSilentSystemAudioDoesNotPretendToProvePermission() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let permissions = PermissionManager(microphone: .granted)
        let system = FakeSystemAudio(
            completion: systemCompletion(
                at: root.appending(path: "system.wav"),
                peakAmplitude: 0
            )
        )
        let controller = RecordingController(
            permissions: permissions,
            sessionRoot: root,
            microphone: FakeMicrophone(),
            systemAudio: system
        )

        await controller.start()
        await controller.stop()

        XCTAssertEqual(permissions.systemAudio, .notDetermined)
    }
}
