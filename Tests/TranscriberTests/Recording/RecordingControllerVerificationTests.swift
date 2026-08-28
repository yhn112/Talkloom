import Foundation
import Testing
import TranscriberCore

@testable import Transcriber

extension RecordingControllerTests {
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

    @Test("one active session owns both capture path states and its final result")
    func oneActiveSessionOwnsBothCapturePathStatesAndItsFinalResult() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RecordingController(
            permissions: PermissionManager(microphone: .granted),
            sessionRoot: root,
            microphone: FakeMicrophone(),
            systemAudio: FakeSystemAudio(shouldFailStart: true)
        )

        await controller.start()
        let session = try #require(controller.currentSession)
        guard case .active(let active) = controller.state else {
            Issue.record("the recording had no active session state")
            return
        }

        #expect(active.session == session)
        #expect(active.phase == .recording)
        guard case .recording = active.microphone else {
            Issue.record("the microphone path was not recording")
            return
        }
        guard case .unavailable(let systemFailure) = active.systemAudio else {
            Issue.record("the failed system path was not represented as unavailable")
            return
        }
        #expect(!systemFailure.isEmpty)
        #expect(active.warning == controller.warning)

        await controller.stop()
        guard case .idle(let storedResult) = controller.state else {
            Issue.record("the completed session was not stored with the idle state")
            return
        }
        let result = try #require(storedResult)

        #expect(result.session == session)
        #expect(result.warning == active.warning)
        #expect(controller.warning == result.warning)
        #expect(controller.currentSession == nil)
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
