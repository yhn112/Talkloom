import AVFoundation
import Foundation
import Testing

@testable import Talkloom

extension DeviceTests {
    /// Diagnostics for what the input node actually delivers. Voice Processing IO changes
    /// the node's channel layout, and the change is invisible until a track comes out quiet
    /// or silent — so what the channels contain is measured here rather than assumed
    /// anywhere else.
    @Suite("voice processing layout")
    struct VoiceProcessingLayout {
        /// Reports the peak of every channel the input node hands over, with and without
        /// voice processing. A channel that is always silent must not be averaged into the
        /// track.
        @Test("every input channel reports its peak", arguments: [false, true])
        func reportsThePeakOfEveryInputChannel(voiceProcessing: Bool) async throws {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(voiceProcessing)
            let format = input.outputFormat(forBus: 0)
            let channelCount = Int(format.channelCount)

            let peaks = Peaks(channelCount: channelCount)
            input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
                peaks.observe(buffer)
            }
            if !voiceProcessing {
                engine.connect(input, to: engine.mainMixerNode, format: format)
                engine.mainMixerNode.outputVolume = 0
            }
            engine.prepare()
            try engine.start()

            let speech = DeviceTests.speak()
            try await Task.sleep(for: .seconds(3))
            speech.terminate()

            input.removeTap(onBus: 0)
            engine.stop()
            try? input.setVoiceProcessingEnabled(false)

            let measured = peaks.values()
            print(
                "  voiceProcessing=\(voiceProcessing) format=\(format.sampleRate) Hz "
                    + "\(channelCount) ch interleaved=\(format.isInterleaved)"
            )
            for (index, peak) in measured.enumerated() {
                print("    channel \(index): peak \(String(format: "%.4f", peak))")
            }
            #expect(measured.first ?? 0 > 0.001, "channel 0 carries the microphone")
        }

        /// Collects a per-channel peak from a real-time tap. Test-only, so a lock is fine.
        private final class Peaks: @unchecked Sendable {
            private let lock = NSLock()
            private var peaks: [Float]

            init(channelCount: Int) { peaks = [Float](repeating: 0, count: channelCount) }

            func observe(_ buffer: AVAudioPCMBuffer) {
                guard let channels = buffer.floatChannelData else { return }
                let frames = Int(buffer.frameLength)
                let channelCount = Int(buffer.format.channelCount)
                lock.lock()
                defer { lock.unlock() }
                for channel in 0..<min(channelCount, peaks.count) {
                    let samples = buffer.format.isInterleaved ? channels[0] : channels[channel]
                    let stride = buffer.format.isInterleaved ? channelCount : 1
                    let offset = buffer.format.isInterleaved ? channel : 0
                    for frame in 0..<frames {
                        peaks[channel] = max(peaks[channel], abs(samples[offset + frame * stride]))
                    }
                }
            }

            func values() -> [Float] {
                lock.lock()
                defer { lock.unlock() }
                return peaks
            }
        }
    }
}
