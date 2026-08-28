import AVFoundation
import Foundation
import Testing
import TranscriberCore

@testable import Transcriber

extension DeviceTests {
    /// Drives the controller the way the menu bar does, against real devices.
    ///
    /// Everything below it is covered elsewhere; what is only exercised here is the wiring —
    /// that pressing record starts both paths, that stopping closes both files, and that the
    /// session ends up describing itself on disk.
    @Suite("recording controller")
    @MainActor
    struct Controller {
        private actor InterruptibleSystemAudio: SystemAudioCapturing {
            private let capture = SystemAudioCapture()
            private var currentRun: CaptureRun?
            private var eventHandler: (@Sendable (CaptureRuntimeEvent) -> Void)?

            func begin(writingTo url: URL) async throws -> CaptureRun {
                let run = try await capture.begin(writingTo: url)
                currentRun = run
                return run
            }

            func verifySignal() async throws -> Bool {
                try await capture.verifySignal()
            }

            func monitorFirstSample(
                _ handler: @escaping @Sendable (UInt64) -> Void
            ) async {
                await capture.monitorFirstSample(handler)
            }

            func observeRuntimeEvents(
                _ handler: @escaping @Sendable (CaptureRuntimeEvent) -> Void
            ) async {
                eventHandler = handler
                await capture.observeRuntimeEvents(handler)
            }

            func restart(
                after event: CaptureRuntimeEvent,
                writingTo nextSegmentURL: URL
            ) async throws -> CaptureRestartResult {
                let result = try await capture.restart(
                    after: event,
                    writingTo: nextSegmentURL)
                if case .restarted(let run) = result { currentRun = run }
                return result
            }

            func finishSession() async -> [TrackRecorder.Completion] {
                eventHandler = nil
                currentRun = nil
                return await capture.finishSession()
            }

            /// A tap-only aggregate can survive a default-output change. In that case the
            /// manual test still forces the same real teardown/rebuild path after the user
            /// switches devices, rather than mistaking uninterrupted HAL delivery for a
            /// restart test.
            func interruptIfNoRestartWasObserved() -> Bool {
                guard let currentRun, currentRun.segmentIndex == 0, let eventHandler else {
                    return false
                }
                eventHandler(
                    CaptureRuntimeEvent(
                        runID: currentRun.id,
                        message: "device-switch verification interruption",
                        retryability: .restartable))
                return true
            }
        }

        private func speak(_ text: String, rate: Int = 165) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-r", String(rate), text]
            try process.run()
            return process
        }

        private func withCaptureCleanup<Result>(
            _ controller: RecordingController,
            operation: () async throws -> Result
        ) async throws -> Result {
            do {
                let result = try await operation()
                await controller.stop()
                return result
            } catch {
                await controller.stop()
                throw error
            }
        }

        private func hasSettledSystemRestart(_ controller: RecordingController) -> Bool {
            guard case .active(let active) = controller.state, active.phase == .recording,
                case .recording(let systemRun) = active.systemAudio,
                systemRun.segmentIndex > 0,
                case .recording = active.microphone
            else { return false }
            return true
        }

        @Test("a recording produces two tracks and a manifest describing them")
        func aRecordingProducesTwoTracksAndAManifest() async throws {
            let root = try DeviceTests.makeDirectory("ControllerDeviceTests")
            defer { try? FileManager.default.removeItem(at: root) }
            let controller = RecordingController(sessionRoot: root)

            await controller.start()
            let session = try #require(
                controller.currentSession,
                "recording did not start: \(controller.errorMessage ?? "no error reported")")
            #expect(controller.isRecording)

            let speech = DeviceTests.speak()
            try await Task.sleep(for: .seconds(3))
            speech.terminate()
            speech.waitUntilExit()

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifestURL = session.directory.appending(path: RecordingManifest.fileName)
            let inProgress = try decoder.decode(
                RecordingManifest.self,
                from: Data(contentsOf: manifestURL))
            #expect(inProgress.status == .recording)
            #expect(
                Set(inProgress.trackStarts.map(\.file)) == ["mic.wav", "system.wav"],
                "both first-sample timestamps reached disk before stop")

            await controller.stop()
            #expect(!controller.isRecording)

            let microphone = try #require(controller.lastMicrophoneTrack)
            let system = try #require(controller.lastSystemTrack)
            #expect(!system.isSilent, "the system track heard nothing")
            #expect(microphone.frameCount > 0)
            #expect(microphone.droppedSampleCount == 0)
            #expect(system.droppedSampleCount == 0)
            print(
                "  microphone: \(String(format: "%.3f", microphone.duration)) s, peak \(String(format: "%.4f", microphone.peakAmplitude)), dropped \(microphone.droppedSampleCount)"
            )
            print(
                "  system: \(String(format: "%.3f", system.duration)) s, peak \(String(format: "%.4f", system.peakAmplitude)), dropped \(system.droppedSampleCount)"
            )

            // The two tracks are never one file, and both actually reached disk.
            #expect(FileManager.default.fileExists(atPath: session.microphoneTrackURL.path))
            #expect(FileManager.default.fileExists(atPath: session.systemTrackURL.path))
            #expect(
                try AVAudioFile(forReading: session.microphoneTrackURL).length
                    == AVAudioFramePosition(microphone.frameCount))
            #expect(
                try AVAudioFile(forReading: session.systemTrackURL).length
                    == AVAudioFramePosition(system.frameCount))

            let data = try Data(contentsOf: manifestURL)
            let manifest = try decoder.decode(RecordingManifest.self, from: data)

            #expect(Set(manifest.tracks.map(\.file)) == ["mic.wav", "system.wav"])
            // Both paths came up, so the microphone is echo-cancelled and carries the user
            // alone. Nothing downstream can work that out from the audio, and this is the
            // only recording of it.
            #expect(manifest.tracks.first { $0.file == "mic.wav" }?.content == .local)
            #expect(manifest.tracks.first { $0.file == "system.wav" }?.content == .remote)
            #expect(manifest.warning == nil, "neither path was degraded")
            for track in manifest.tracks {
                let spans = try #require(track.spans)
                #expect(spans.count == 1)
                let span = try #require(spans.first)
                #expect(span.fileFrameOffset == 0)
                #expect(span.frameCount == track.frameCount)
                #expect(track.gaps?.isEmpty == true)
                print(
                    "  \(track.file): one continuous span, \(span.frameCount) frames, no gaps"
                )
            }
            // The system tap produces its first sample almost at once; voice processing
            // takes the best part of a second to come up. The gap is accepted, but it has to
            // be written down, because nothing in the audio records it.
            #expect(
                manifest.tracks.compactMap(\.startOffset).min() == 0,
                "the earliest track defines the origin")
            let micOffset = try #require(
                manifest.tracks.first { $0.file == "mic.wav" }?.startOffset)
            print("  microphone starts \(String(format: "%.3f", micOffset)) s after the system tap")
            #expect(micOffset > 0)
            #expect(micOffset < 5)
        }

        @Test(
            "an output-device switch preserves both logical tracks",
            .enabled(
                if: ProcessInfo.processInfo.environment["TRANSCRIBER_DEVICE_SWITCH_TEST"]
                    == "1",
                "run through the TranscriberDeviceSwitchTests scheme only when a person is ready to switch output devices"
            )
        )
        func outputDeviceSwitchPreservesBothLogicalTracks() async throws {
            let rootPath = try #require(
                ProcessInfo.processInfo.environment["TRANSCRIBER_DEVICE_SWITCH_ROOT"],
                "run this interactive test through scripts/device-switch-test.sh")
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let systemAudio = InterruptibleSystemAudio()
            let controller = RecordingController(
                sessionRoot: root,
                systemAudio: systemAudio)
            var spawnedProcesses: [Process] = []
            defer {
                for process in spawnedProcesses where process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }

            try await withCaptureCleanup(controller) {
                await controller.start()
                let session = try #require(
                    controller.currentSession,
                    "recording did not start: \(controller.errorMessage ?? "no error reported")")

                var speech = try speak(
                    "Before the device switch. One two three four five six seven eight.")
                spawnedProcesses.append(speech)
                try await Task.sleep(for: .seconds(3))
                speech.terminate()
                speech.waitUntilExit()

                let cue = try speak(
                    "Switch the output device now, then say: switch complete, into the microphone.",
                    rate: 145)
                spawnedProcesses.append(cue)
                try await Task.sleep(for: .seconds(4))
                cue.terminate()
                cue.waitUntilExit()
                print("  waiting six seconds for the manual output-device switch")
                try await Task.sleep(for: .seconds(6))

                let forced = await systemAudio.interruptIfNoRestartWasObserved()
                print(
                    forced
                        ? "  tap survived the switch; forcing its real restart path"
                        : "  the tap reported its own interruption after the switch")
                for _ in 0..<200 where !hasSettledSystemRestart(controller) {
                    try await Task.sleep(for: .milliseconds(50))
                }
                try #require(
                    hasSettledSystemRestart(controller),
                    "the system path or its microphone fallback did not settle after restart")
                #expect(controller.warning != nil, "the interruption must remain visible")

                speech = try speak(
                    "After the device switch. Alpha beta gamma delta epsilon zeta eta theta. Please say: restart complete, into the microphone."
                )
                spawnedProcesses.append(speech)
                try await Task.sleep(for: .seconds(5))
                speech.terminate()
                speech.waitUntilExit()
                await controller.stop()

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let manifest = try decoder.decode(
                    RecordingManifest.self,
                    from: Data(
                        contentsOf: session.directory.appending(
                            path: RecordingManifest.fileName)))
                let microphone = manifest.segments(for: .microphone)
                let system = manifest.segments(for: .systemAudio)
                #expect(manifest.status == .completed)
                #expect(manifest.failure == nil)
                #expect(manifest.warning == controller.warning)
                #expect(!microphone.isEmpty)
                #expect(system.count >= 2)

                let firstSystem = try #require(system.first)
                let restartedSystem = try #require(system.last)
                let finalMicrophone = try #require(microphone.last)
                let restartGap = try #require(restartedSystem.gaps?.first)
                let postRestartSpan = try #require(restartedSystem.spans?.last)

                #expect(firstSystem.frameCount > 0)
                #expect(restartGap.fileFrameOffset == 0)
                #expect(restartGap.frameCount > 0)
                #expect(postRestartSpan.fileFrameOffset == restartGap.frameCount)
                #expect(postRestartSpan.frameCount > 0)
                #expect((restartedSystem.peakAmplitude ?? 0) > 0.01)
                #expect((finalMicrophone.peakAmplitude ?? 0) > 0.001)
                #expect(
                    Set(system.compactMap(\.segmentIndex))
                        == Set(0..<system.count))
                #expect(
                    Set(microphone.compactMap(\.segmentIndex))
                        == Set(0..<microphone.count))

                for track in microphone + system {
                    #expect(
                        FileManager.default.fileExists(
                            atPath: session.directory.appending(path: track.file).path))
                    #expect(
                        try AVAudioFile(
                            forReading: session.directory.appending(path: track.file)
                        ).length
                            == AVAudioFramePosition(track.frameCount))
                }

                let microphoneEnd =
                    try #require(finalMicrophone.startOffset)
                    + Double(finalMicrophone.frameCount) / finalMicrophone.sampleRate
                let systemEnd =
                    try #require(restartedSystem.startOffset)
                    + Double(restartedSystem.frameCount) / restartedSystem.sampleRate
                #expect(abs(microphoneEnd - systemEnd) < 2)

                for segment in microphone {
                    print(
                        "  \(segment.file): \(segment.sampleRate) Hz, \(String(format: "%.3f", Double(segment.frameCount) / segment.sampleRate)) s, peak \(String(format: "%.4f", segment.peakAmplitude ?? 0))"
                    )
                }
                for segment in system {
                    print(
                        "  \(segment.file): \(segment.sampleRate) Hz, \(String(format: "%.3f", Double(segment.frameCount) / segment.sampleRate)) s, peak \(String(format: "%.4f", segment.peakAmplitude ?? 0))"
                    )
                }
                print(
                    "  restart gap: \(restartGap.frameCount) frames at \(restartedSystem.sampleRate) Hz = \(String(format: "%.3f", restartGap.duration)) s"
                )
                print(
                    "  logical end difference: |mic \(String(format: "%.3f", microphoneEnd)) - system \(String(format: "%.3f", systemEnd))| = \(String(format: "%.3f", abs(microphoneEnd - systemEnd))) s"
                )
            }
        }
    }
}
