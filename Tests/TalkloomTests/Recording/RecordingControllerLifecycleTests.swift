import Foundation
import TalkloomCore
import Testing

@testable import Talkloom

extension RecordingControllerTests {
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
}
