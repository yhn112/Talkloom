import AVFoundation
import Foundation
import Testing

@testable import Transcriber

extension DeviceTests {
    /// Records from the real microphone. Compiling proves nothing about capture code — the
    /// failure mode is a valid file of the right duration containing silence — so these are
    /// the tests that decide whether the microphone path works.
    @Suite("microphone capture")
    final class Microphone {
        private let directory: URL

        init() throws {
            directory = try DeviceTests.makeDirectory("MicrophoneDeviceTests")
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        private func record(
            voiceProcessing: Bool,
            to name: String,
            using capture: MicrophoneCapture = MicrophoneCapture()
        ) async throws -> TrackRecorder.Summary {
            let url = directory.appending(path: name)

            _ = try await capture.start(writingTo: url, voiceProcessing: voiceProcessing)
            let speech = DeviceTests.speak()
            try await Task.sleep(for: .seconds(4))
            speech.terminate()
            let result = try #require(await capture.stop()).summary
            // Printed because these numbers are the verification: a commit touching capture
            // has to carry the measured peak per track, not the assertion that it compiled.
            print(
                "  [\(name)] voiceProcessing=\(voiceProcessing) rate=\(result.sampleRate) Hz "
                    + "frames=\(result.frameCount) duration=\(String(format: "%.2f", result.duration)) s "
                    + "peak=\(String(format: "%.4f", result.peakAmplitude)) dropped=\(result.droppedSampleCount)"
            )
            return result
        }

        /// The whole chain against real hardware, with echo cancellation out of the way so
        /// the speakers reach the microphone: device → tap → ring buffer → resample-free WAV.
        @Test("the microphone records audible audio")
        func theMicrophoneRecordsAudibleAudio() async throws {
            let summary = try await record(voiceProcessing: false, to: "raw.wav")

            #expect(abs(summary.duration - 4.0) < 0.5)
            #expect(summary.droppedSampleCount == 0, "the drain loop kept up with the device")
            #expect(!summary.isSilent, "peak was \(summary.peakAmplitude) — the file is silent")
            #expect(summary.peakAmplitude > 0.01, "the microphone heard the speakers")
            // Not an assertion about the code — a warning about this machine's input gain,
            // which would distort a real meeting the same way.
            if summary.isClipped {
                print(
                    "  warning: the microphone clipped at \(summary.peakAmplitude); the input volume is too high"
                )
            }

            // The file on disk must agree with what the recorder reported.
            let file = try AVAudioFile(forReading: summary.url)
            #expect(file.fileFormat.sampleRate == summary.sampleRate)
            #expect(file.fileFormat.channelCount == 1)
            #expect(file.length == AVAudioFramePosition(summary.frameCount))
        }

        /// The app keeps one `MicrophoneCapture` for the life of the process, so a mic-only
        /// fallback and a normal session land on the same object, one after the other. Every
        /// other test here builds a fresh instance, so nothing covered that sequence — and
        /// the two modes need different engine graphs, which made it worth pinning down
        /// rather than assuming. Measured over nine runs: both sessions record, at the
        /// device's rate, with nothing dropped.
        ///
        /// It also pins the labels down. Without cancellation the remote side is in the
        /// microphone file, and calling that track "me" is what would put other people's
        /// words in the user's mouth in the transcript.
        @Test("a fallback session and the next normal one both record")
        func aFallbackSessionAndTheNextNormalOneBothRecord() async throws {
            let capture = MicrophoneCapture()

            let fallback = try await record(
                voiceProcessing: false, to: "fallback.wav", using: capture)
            let normal = try await record(voiceProcessing: true, to: "normal.wav", using: capture)

            #expect(!fallback.isSilent, "peak was \(fallback.peakAmplitude)")
            #expect(normal.frameCount > 0, "the second session recorded nothing")
            #expect(normal.droppedSampleCount == 0)
            #expect(fallback.content == .mixed)
            #expect(normal.content == .local)

            // Deliberately no assertion on how much quieter the second track is.
            // Cancellation converges over the first seconds of a session, so a peak taken
            // across a short recording measures where the loud syllables happened to fall:
            // the same configuration measured 0.0057, 0.0064, 0.0078, 0.0835 and 0.6105
            // over five runs.
        }

        /// Regression for the in-session safety transition used when system audio can no
        /// longer be verified. Releasing the Voice Processing IO engine as the raw engine
        /// started reproduced an EXC_BAD_ACCESS on AVFAudio's internal property-listener
        /// queue; both physical segments must now survive the transition.
        @Test("voice processing can fall back to a raw segment")
        func voiceProcessingCanFallBackToARawSegment() async throws {
            let capture = MicrophoneCapture()
            let voiceURL = directory.appending(path: "reconfigure-voice.wav")
            let rawURL = directory.appending(path: "reconfigure-raw.wav")

            do {
                let voiceRun = try await capture.begin(
                    writingTo: voiceURL,
                    voiceProcessing: true
                )
                try await Task.sleep(for: .seconds(1))

                let rawRun: CaptureRun
                switch try await capture.reconfigure(
                    run: voiceRun,
                    writingTo: rawURL,
                    voiceProcessing: false
                ) {
                case .stale:
                    Issue.record("the live voice-processed run was treated as stale")
                    _ = await capture.finishSession()
                    return
                case .restarted(let run):
                    rawRun = run
                }
                try await Task.sleep(for: .seconds(1))

                let completions = await capture.finishSession()
                #expect(rawRun.segmentIndex == 1)
                #expect(completions.count == 2)
                #expect(completions.map(\.summary.segmentIndex) == [0, 1])
                #expect(completions.map(\.summary.content) == [.local, .mixed])
                #expect(completions.allSatisfy { $0.failure == nil })
                #expect(completions.allSatisfy { $0.summary.frameCount > 0 })
                #expect(completions.allSatisfy { $0.summary.droppedSampleCount == 0 })
            } catch {
                _ = await capture.finishSession()
                throw error
            }
        }

        /// Echo cancellation has to actually cancel. A canceller that silently does nothing
        /// looks identical from the API's side, and only shows up later as every remote line
        /// appearing twice in the transcript.
        @Test("voice processing suppresses the speakers")
        func voiceProcessingSuppressesTheSpeakers() async throws {
            let withoutCancellation = try await record(voiceProcessing: false, to: "raw.wav")
            let withCancellation = try await record(voiceProcessing: true, to: "aec.wav")

            #expect(!withoutCancellation.isSilent, "the reference recording heard nothing")
            #expect(
                withCancellation.peakAmplitude < withoutCancellation.peakAmplitude,
                "echo cancellation made no difference: \(withCancellation.peakAmplitude) vs \(withoutCancellation.peakAmplitude)"
            )
        }
    }
}
