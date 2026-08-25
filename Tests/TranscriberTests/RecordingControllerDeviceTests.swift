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
    }
}
