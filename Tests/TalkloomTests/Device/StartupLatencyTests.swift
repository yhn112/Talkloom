import AVFoundation
import CoreAudio
import Foundation
import TalkloomCore
import Testing

@testable import Talkloom

extension DeviceTests {
    /// Times what happens between pressing record and the first microphone sample.
    ///
    /// The gap is not cosmetic: the system tap starts immediately, so every second the
    /// microphone spends starting up is a second of the meeting recorded from one side
    /// only. Measured on a real recording, it was 2.709 s.
    @Suite("startup latency")
    struct StartupLatency {
        private func time(_ label: String, _ body: () throws -> Void) rethrows {
            let start = ContinuousClock.now
            try body()
            let seconds = Double((ContinuousClock.now - start).components.attoseconds) / 1e18
            print("    \(label): \(String(format: "%.3f", seconds)) s")
        }

        @Test("where the microphone startup time goes", arguments: [false, true])
        func whereTheMicrophoneStartupTimeGoes(voiceProcessing: Bool) throws {
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

        /// Time from asking for capture to the first sample actually arriving.
        ///
        /// This is the number that matters, and it is not the time the start call takes: the
        /// engine returns long before the unit delivers anything. Whatever separates the two
        /// paths here is missing from one track of every recording.
        @Test("time to the first sample on both paths")
        func timeToTheFirstSampleOnBothPaths() async throws {
            // One microphone reused across recordings, the way the app holds it: a
            // MicrophoneCapture is a long-lived object, and building a fresh one per
            // recording churns AVAudioEngine lifecycles in a way the framework does not
            // survive.
            let microphone = MicrophoneCapture()
            for _ in 0..<3 {
                let systemAudio = SystemAudioCapture()
                let directory = try DeviceTests.makeDirectory("Latency")
                defer { try? FileManager.default.removeItem(at: directory) }

                let requested = mach_absolute_time()
                _ = try await systemAudio.start(writingTo: directory.appending(path: "system.wav"))
                let systemReturned = mach_absolute_time()
                _ = try await microphone.start(writingTo: directory.appending(path: "mic.wav"))
                let microphoneReturned = mach_absolute_time()

                try await Task.sleep(for: .seconds(2))
                let micTrack = try #require(await microphone.stop()).summary
                let systemTrack = try #require(await systemAudio.stop()).summary

                let systemFirst = try #require(systemTrack.firstSampleHostTime)
                let microphoneFirst = try #require(micTrack.firstSampleHostTime)
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
        private func inputDeviceIsRunning() throws -> Bool {
            guard let device = try AudioHardwareSystem.shared.defaultInputDevice else {
                return false
            }
            return try device.isRunningInAProcess
        }

        @Test("the microphone is released between recordings")
        func theMicrophoneIsReleasedBetweenRecordings() async throws {
            let microphone = MicrophoneCapture()
            let directory = try DeviceTests.makeDirectory("Release")
            defer { try? FileManager.default.removeItem(at: directory) }

            let runningBeforeStart = try inputDeviceIsRunning()
            #expect(
                !runningBeforeStart,
                "something was already using the microphone before the test")

            _ = try await microphone.start(writingTo: directory.appending(path: "first.wav"))
            try await Task.sleep(for: .milliseconds(500))
            let runningWhileRecording = try inputDeviceIsRunning()
            #expect(runningWhileRecording, "recording should hold the device")

            _ = await microphone.stop()
            try await Task.sleep(for: .milliseconds(500))
            // Voice processing stays enabled on the node; the device must not stay held.
            let runningAfterStop = try inputDeviceIsRunning()
            #expect(
                !runningAfterStop,
                "the microphone is still in use after stopping — the indicator would stay lit while idle"
            )

            // And it can still be started again afterwards.
            _ = try await microphone.start(writingTo: directory.appending(path: "second.wav"))
            try await Task.sleep(for: .milliseconds(500))
            let second = try #require(await microphone.stop()).summary
            #expect(second.frameCount > 0)
        }

        /// The same engine started twice: if the cost is one-off per process rather than per
        /// recording, warming it up at launch removes the gap entirely.
        @Test("whether a warm engine starts faster")
        func whetherAWarmEngineStartsFaster() throws {
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
}
