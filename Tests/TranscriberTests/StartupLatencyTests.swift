import AVFoundation
import CoreAudio
import TranscriberCore
import XCTest

@testable import Transcriber

/// Times what happens between pressing record and the first microphone sample.
///
/// The gap is not cosmetic: the system tap starts immediately, so every second the
/// microphone spends starting up is a second of the meeting recorded from one side only.
/// Measured on a real recording, it was 2.709 s.
final class StartupLatencyTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TRANSCRIBER_DEVICE_TESTS"] == "1",
            "set TRANSCRIBER_DEVICE_TESTS=1 to run the tests that use real audio devices"
        )
    }

    private func time(_ label: String, _ body: () throws -> Void) rethrows {
        let start = ContinuousClock.now
        try body()
        print(
            "    \(label): \(String(format: "%.3f", Double((ContinuousClock.now - start).components.attoseconds) / 1e18)) s"
        )
    }

    func testWhereTheMicrophoneStartupTimeGoes() throws {
        for voiceProcessing in [false, true] {
            print("  voiceProcessing=\(voiceProcessing)")
            let engine = AVAudioEngine()
            let input = engine.inputNode

            try time("setVoiceProcessingEnabled") {
                try input.setVoiceProcessingEnabled(voiceProcessing)
            }
            var format = AVAudioFormat()
            time("outputFormat(forBus:)") {
                format = input.outputFormat(forBus: 0)
            }
            time("installTap") {
                input.installTap(onBus: 0, bufferSize: 4_096, format: format) { _, _ in }
            }
            if !voiceProcessing {
                engine.connect(input, to: engine.mainMixerNode, format: format)
                engine.mainMixerNode.outputVolume = 0
            }
            time("prepare") { engine.prepare() }
            try time("start") { try engine.start() }

            input.removeTap(onBus: 0)
            engine.stop()
            try? input.setVoiceProcessingEnabled(false)
        }
    }

    /// Time from asking for capture to the first sample actually arriving.
    ///
    /// This is the number that matters, and it is not the time the start call takes: the
    /// engine returns long before the unit delivers anything. Whatever separates the two
    /// paths here is missing from one track of every recording.
    func testTimeToTheFirstSampleOnBothPaths() async throws {
        // One microphone reused across recordings, the way the app holds it: a
        // MicrophoneCapture is a long-lived object, and building a fresh one per recording
        // churns AVAudioEngine lifecycles in a way the framework does not survive.
        let microphone = MicrophoneCapture()
        for _ in 0..<3 {
            let systemAudio = SystemAudioCapture()
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "Latency-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let requested = mach_absolute_time()
            _ = try await systemAudio.start(writingTo: directory.appending(path: "system.wav"))
            let systemReturned = mach_absolute_time()
            _ = try await microphone.start(writingTo: directory.appending(path: "mic.wav"))
            let microphoneReturned = mach_absolute_time()

            try await Task.sleep(for: .seconds(2))
            let stoppedMicrophone = await microphone.stop()
            let stoppedSystem = await systemAudio.stop()
            let micTrack = try XCTUnwrap(stoppedMicrophone).summary
            let systemTrack = try XCTUnwrap(stoppedSystem).summary

            let systemFirst = try XCTUnwrap(systemTrack.firstSampleHostTime)
            let microphoneFirst = try XCTUnwrap(micTrack.firstSampleHostTime)
            print(
                "    system: start returned +\(String(format: "%.3f", HostTime.seconds(from: requested, to: systemReturned))) s, "
                    + "first sample +\(String(format: "%.3f", HostTime.seconds(from: requested, to: systemFirst))) s"
            )
            print(
                "    mic:    start returned +\(String(format: "%.3f", HostTime.seconds(from: systemReturned, to: microphoneReturned))) s, "
                    + "first sample +\(String(format: "%.3f", HostTime.seconds(from: requested, to: microphoneFirst))) s"
            )
            print(
                "    gap between the two tracks: \(String(format: "%.3f", HostTime.seconds(from: systemFirst, to: microphoneFirst))) s"
            )
        }
    }

    /// Is the default input device running for anyone on this machine?
    ///
    /// This is what lights the orange microphone indicator in the menu bar. Voice
    /// processing is deliberately left enabled between recordings, and the promise that
    /// comes with that is checked here rather than taken on trust: a stopped engine must
    /// release the device even though its unit is still configured.
    private func inputDeviceIsRunning() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
                == noErr
        else { return false }

        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    func testTheMicrophoneIsReleasedBetweenRecordings() async throws {
        let microphone = MicrophoneCapture()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "Release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(
            inputDeviceIsRunning(), "something was already using the microphone before the test")

        _ = try await microphone.start(writingTo: directory.appending(path: "first.wav"))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(inputDeviceIsRunning(), "recording should hold the device")

        _ = await microphone.stop()
        try await Task.sleep(for: .milliseconds(500))
        // Voice processing stays enabled on the node; the device must not stay held.
        XCTAssertFalse(
            inputDeviceIsRunning(),
            "the microphone is still in use after stopping — the indicator would stay lit while idle"
        )

        // And it can still be started again afterwards.
        _ = try await microphone.start(writingTo: directory.appending(path: "second.wav"))
        try await Task.sleep(for: .milliseconds(500))
        let stopped = await microphone.stop()
        let second = try XCTUnwrap(stopped).summary
        XCTAssertGreaterThan(second.frameCount, 0)
    }

    /// The same engine started twice: if the cost is one-off per process rather than per
    /// recording, warming it up at launch removes the gap entirely.
    func testWhetherAWarmEngineStartsFaster() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { _, _ in }

        engine.prepare()
        try time("first start") { try engine.start() }
        engine.stop()
        try time("second start") { try engine.start() }
        engine.stop()
        try time("third start") { try engine.start() }

        input.removeTap(onBus: 0)
        engine.stop()
        try? input.setVoiceProcessingEnabled(false)
    }
}
