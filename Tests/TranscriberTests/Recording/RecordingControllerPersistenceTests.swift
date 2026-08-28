import Foundation
import Testing
import TranscriberCore

@testable import Transcriber

extension RecordingControllerTests {
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
        guard case .failed(let failureState) = controller.state else {
            Issue.record("the failed recording had no unified failure state")
            return
        }
        #expect(failureState.recording?.systemAudio.last?.frameCount == 24_000)
        #expect(failureState.message == controller.errorMessage)
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
}
