import AVFoundation
import Foundation
import TalkloomCore
import Testing

@testable import Talkloom

extension DeviceTests {
    /// Measures what Voice Processing IO does to the audio the process tap records.
    ///
    /// Voice processing ducks "other audio" so a voice chat stays intelligible. Here the
    /// other audio is the meeting, and the tap records it — so ducking would quiet the
    /// remote participants in the very track that is supposed to carry them. The setting
    /// meant to prevent that is `voiceProcessingOtherAudioDuckingConfiguration`, and
    /// whether it works is a measurement, not a documented guarantee.
    ///
    /// This stays one test rather than a case per configuration: the assertion is about the
    /// ranking of the whole table — which setting keeps the meeting loudest — and a single
    /// row cannot answer it. Every level is also measured against a reference recording made
    /// in the same conditions, which would have to be repeated per case.
    @Suite("ducking measurement")
    final class Ducking {
        private let directory: URL

        init() throws {
            directory = try DeviceTests.makeDirectory("Ducking")
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        /// A fixed tone rather than speech: the comparison is only meaningful if what is
        /// played is identical every time, and `say` is not.
        private func makeTone() throws -> URL {
            let url = directory.appending(path: "tone.wav")
            let writer = try WAVWriter(url: url, sampleRate: 48_000, channelCount: 1)
            let samples = (0..<(48_000 * 6)).map { index -> Int16 in
                let phase: Double = 2 * Double.pi * 440 * Double(index) / 48_000
                let value: Double = 0.5 * sin(phase)
                return Int16(value * 32_767)
            }
            try samples.withUnsafeBufferPointer { try writer.append($0) }
            try writer.finish()
            return url
        }

        private func play(_ url: URL) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            process.arguments = [url.path]
            try? process.run()
            return process
        }

        /// Kills the playback and waits for it to be gone.
        ///
        /// `terminate()` only asks. Without the wait the next measurement starts while the
        /// previous tone is still sounding, and two tones sum — measured at 1.04 against an
        /// expected 0.5, which silently doubled one side of a comparison.
        private func stop(_ playback: Process) {
            playback.terminate()
            playback.waitUntilExit()
        }

        /// Steady-state level of a recorded track, in dBFS.
        ///
        /// RMS over a window taken after the level has settled, not the peak over the whole
        /// recording. Ducking ramps in rather than switching, so a peak measured across the
        /// ramp reports whatever fraction of the un-ducked opening happened to land in the
        /// window — which is how the same configuration came back at 0.44 and at 0.199 on
        /// consecutive runs. Peak answers "is this silent"; it does not answer "how loud".
        private func settledLevel(of url: URL, skipping lead: Double = 1.5, over span: Double = 1.0)
            throws -> Double
        {
            let file = try AVAudioFile(forReading: url)
            let rate = file.fileFormat.sampleRate
            let start = AVAudioFramePosition(lead * rate)
            let count = AVAudioFrameCount(min(span * rate, Double(file.length) - Double(start)))
            guard start < file.length, count > 0 else { return -.infinity }

            let format = try #require(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                    interleaved: false))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
            file.framePosition = start
            try file.read(into: buffer, frameCount: count)

            let samples = try #require(buffer.floatChannelData)[0]
            var sum = 0.0
            for index in 0..<Int(buffer.frameLength) {
                sum += Double(samples[index]) * Double(samples[index])
            }
            let rms = (sum / Double(buffer.frameLength)).squareRoot()
            return rms > 0 ? 20 * log10(rms) : -.infinity
        }

        /// Fails rather than measures if anything is still playing from an earlier test.
        private func expectNothingIsPlaying() throws {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            check.arguments = ["-x", "afplay"]
            let pipe = Pipe()
            check.standardOutput = pipe
            try check.run()
            check.waitUntilExit()
            let output = String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(
                output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "a previous test left audio playing; every level below would be measured against it"
            )
        }

        private func measure(
            _ ducking: AVAudioVoiceProcessingOtherAudioDuckingConfiguration?,
            playing tone: URL
        ) async throws -> Double {
            try expectNothingIsPlaying()
            let microphone = MicrophoneCapture()
            let systemAudio = SystemAudioCapture()
            let url = directory.appending(path: "\(UUID().uuidString).wav")

            let playback = play(tone)
            try await Task.sleep(for: .milliseconds(500))
            if let ducking {
                _ = try await microphone.start(
                    writingTo: directory.appending(path: "\(UUID().uuidString)-mic.wav"),
                    ducking: ducking
                )
            }
            _ = try await systemAudio.start(writingTo: url)
            try await Task.sleep(for: .seconds(4))

            _ = await systemAudio.stop()
            if ducking != nil { _ = await microphone.stop() }
            stop(playback)
            return try settledLevel(of: url)
        }

        /// Ranks every ducking configuration by how much of the system audio survives.
        @Test("the least ducked configuration is the one in use")
        func theLeastDuckedConfigurationIsTheOneInUse() async throws {
            let tone = try makeTone()

            let reference = try await measure(nil, playing: tone)
            print("  no microphone: \(String(format: "%.1f", reference)) dBFS")

            let levels: [(String, AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level)] = [
                ("default", .default), ("min", .min), ("mid", .mid), ("max", .max),
            ]
            var measured: [(name: String, level: Double)] = []
            for advanced in [false, true] {
                for (name, level) in levels {
                    let dBFS = try await measure(
                        .init(enableAdvancedDucking: ObjCBool(advanced), duckingLevel: level),
                        playing: tone
                    )
                    let label = "advanced=\(advanced) level=\(name)"
                    measured.append((label, dBFS))
                    print(
                        "  \(label): \(String(format: "%.1f", dBFS)) dBFS (\(String(format: "%+.1f", dBFS - reference)) dB)"
                    )
                }
            }

            let best = try #require(measured.max { $0.level < $1.level })
            print("  least ducked: \(best.name)")
            #expect(
                best.name == "advanced=false level=min",
                "the configuration MicrophoneCapture uses is no longer the one that keeps the meeting loudest"
            )
            #expect(best.level > -40, "the system track is too quiet to transcribe")
        }
    }
}
