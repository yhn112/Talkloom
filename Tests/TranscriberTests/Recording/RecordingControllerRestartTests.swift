import Foundation
import Testing
import TranscriberCore

@testable import Transcriber

extension RecordingControllerTests {
    @Test("a runtime failure restarts only its capture path")
    func runtimeFailureRestartsOnlyItsCapturePath() async throws {
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
        for _ in 0..<20 where (await system.restartCount) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(controller.currentSession == session)
        #expect(controller.errorMessage == nil)
        #expect(await system.restartCount == 1)
        #expect(await microphone.restartCount == 0)
        #expect(await microphone.endCount == 0)
        #expect(await system.endCount == 0)
        #expect(controller.warning?.contains("interrupted and restored") == true)

        await controller.stop()
        #expect(try manifest(in: session).failure == nil)
    }

    @Test("a changed-rate restart remains one logical system track")
    func changedRateRestartRemainsOneLogicalSystemTrack() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let origin: UInt64 = 1_000
        let firstEnd = origin + HostTime.hostTicks(forSeconds: 1)
        let resumedAt = firstEnd + HostTime.hostTicks(forSeconds: 0.5)
        let system = FakeSystemAudio(
            completion: systemCompletion(
                at: root.appending(path: "system-2.wav"),
                segmentIndex: 1,
                sampleRate: 44_100,
                frameCount: 66_150,
                firstSampleHostTime: firstEnd,
                spans: [
                    TrackReport.Span(
                        fileFrameOffset: 22_050,
                        frameCount: 44_100,
                        startHostTime: resumedAt)
                ]
            ),
            restartCompletion: systemCompletion(
                at: root.appending(path: "system.wav"),
                frameCount: 48_000,
                firstSampleHostTime: origin)
        )
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: FakeMicrophone(),
            systemAudio: system
        )
        await controller.start()
        let session = try #require(controller.currentSession)

        await system.fail("sample rate changed")
        for _ in 0..<50 where controller.warning?.contains("restored") != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        await controller.stop()

        let segments = try manifest(in: session).segments(for: .systemAudio)
        #expect(segments.map(\.file) == ["system.wav", "system-2.wav"])
        #expect(segments.map(\.segmentIndex) == [0, 1])
        #expect(segments.map(\.sampleRate) == [48_000, 44_100])
        #expect(segments[1].startOffset == 1)
        let gap = try #require(segments[1].gaps?.first)
        #expect(gap.fileFrameOffset == 0)
        #expect(gap.frameCount == 22_050)
        #expect(gap.duration == 0.5)
        #expect(segments[1].spans?.first?.startOffset == 1.5)
    }

    @Test("a failed restart probe disables microphone echo cancellation")
    func failedRestartProbeDisablesMicrophoneEchoCancellation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone()
        let system = FakeSystemAudio(restartVerifiedSignal: false)
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: microphone,
            systemAudio: system
        )
        await controller.start()

        await system.fail("device disappeared")
        for _ in 0..<50 where await microphone.lastVoiceProcessing != false {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(controller.isRecording)
        #expect(controller.errorMessage == nil)
        #expect(await microphone.restartCount == 1)
        #expect(await microphone.lastVoiceProcessing == false)
        #expect(controller.warning?.contains("verification signal") == true)
        #expect(controller.warning?.contains("without echo cancellation") == true)
        await controller.stop()
    }

    @Test("restart exhaustion degrades one path and preserves remote audio")
    func restartExhaustionDegradesOnePathAndPreservesRemoteAudio() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone()
        let system = FakeSystemAudio(restartFailures: 3)
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: microphone,
            systemAudio: system
        )
        await controller.start()

        await system.fail("device disappeared")
        for _ in 0..<50 where (await microphone.restartCount) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(controller.isRecording)
        #expect(controller.errorMessage == nil)
        #expect(await system.restartCount == 3)
        #expect(await microphone.restartCount == 1)
        #expect(await microphone.lastVoiceProcessing == false)
        guard case .active(let active) = controller.state else {
            Issue.record("the degraded session was no longer active")
            return
        }
        guard case .unavailable = active.systemAudio else {
            Issue.record("restart exhaustion was not visible in the path state")
            return
        }
        guard case .recording = active.microphone else {
            Issue.record("the unaffected microphone path was not recording")
            return
        }
        #expect(controller.warning?.contains("could not be restored") == true)
        #expect(controller.warning?.contains("without echo cancellation") == true)
        await controller.stop()
    }

    @Test("stop during a suspended restart cannot resurrect capture")
    func stopDuringSuspendedRestartCannotResurrectCapture() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = FakeMicrophone()
        let system = FakeSystemAudio(restartDelay: .milliseconds(100))
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: microphone,
            systemAudio: system
        )
        await controller.start()

        await system.fail("device disappeared")
        while (await system.restartCount) == 0 { await Task.yield() }
        await controller.stop()
        try await Task.sleep(for: .milliseconds(120))

        #expect(!controller.isRecording)
        #expect(controller.currentSession == nil)
        #expect(await microphone.endCount == 1)
        #expect(await system.endCount == 1)
    }

    @Test("a delayed runtime failure cannot stop the next session")
    func delayedRuntimeFailureCannotStopNextSession() async throws {
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
        let firstSession = try #require(controller.currentSession)
        await controller.stop()
        await controller.start()
        let secondSession = try #require(controller.currentSession)
        #expect(secondSession != firstSession)

        await system.failRetiredSession("previous device disappeared")
        try await Task.sleep(for: .milliseconds(10))

        #expect(controller.currentSession == secondSession)
        #expect(controller.errorMessage == nil)
        #expect(await microphone.endCount == 1)
        #expect(await system.endCount == 1)
        await controller.stop()
    }

    /// This is inspected before stop: the final manifest already carried the offsets. The
    /// regression is specifically whether a kill during capture loses the only alignment.
}
