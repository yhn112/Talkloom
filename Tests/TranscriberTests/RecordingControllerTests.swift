import XCTest

@testable import Transcriber

@MainActor
final class RecordingControllerTests: XCTestCase {
    private actor FakeMicrophone: MicrophoneCapturing {
        let shouldFailStart: Bool
        private(set) var beginCount = 0
        private(set) var endCount = 0
        private var failureHandler: (@Sendable (String) -> Void)?

        init(shouldFailStart: Bool = false) { self.shouldFailStart = shouldFailStart }

        func begin(writingTo url: URL, voiceProcessing: Bool) async throws {
            beginCount += 1
            if shouldFailStart { throw CocoaError(.fileWriteUnknown) }
        }

        func monitorRuntimeFailures(_ handler: @escaping @Sendable (String) -> Void) {
            failureHandler = handler
        }

        func end() -> TrackRecorder.Summary? {
            endCount += 1
            failureHandler = nil
            return nil
        }
    }

    private actor FakeSystemAudio: SystemAudioCapturing {
        let startDelay: Duration
        let endDelay: Duration
        private(set) var beginCount = 0
        private(set) var endCount = 0
        private var failureHandler: (@Sendable (String) -> Void)?

        init(startDelay: Duration = .zero, endDelay: Duration = .zero) {
            self.startDelay = startDelay
            self.endDelay = endDelay
        }

        func begin(writingTo url: URL) async throws {
            beginCount += 1
            if startDelay > .zero { try await Task.sleep(for: startDelay) }
        }

        func monitorRuntimeFailures(_ handler: @escaping @Sendable (String) -> Void) {
            failureHandler = handler
        }

        func end() async -> TrackRecorder.Summary? {
            endCount += 1
            if endDelay > .zero { try? await Task.sleep(for: endDelay) }
            failureHandler = nil
            return nil
        }

        func fail(_ message: String) { failureHandler?(message) }
    }

    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "RecordingControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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

        await system.fail("device disappeared")
        for _ in 0..<20 where controller.errorMessage == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let microphoneEndCount = await microphone.endCount
        let systemEndCount = await system.endCount
        XCTAssertEqual(controller.errorMessage, "System audio capture stopped: device disappeared")
        XCTAssertEqual(microphoneEndCount, 1)
        XCTAssertEqual(systemEndCount, 1)
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
}
