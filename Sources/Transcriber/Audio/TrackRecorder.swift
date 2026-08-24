import AVFoundation
import Foundation

/// One recorded track, end to end: the handle an audio callback writes into, and the
/// consumer that drains it and writes the file.
///
/// The consumer does as little as possible: it writes the device's own sample rate straight
/// to disk. Producing the 16 kHz mono copy ASR wants happens once, afterwards, over the
/// finished file (`afconvert`, see `PLAN.md` stage 2). Nothing here has to keep up with
/// anything — this project transcribes after the meeting, so the recording is the master
/// and accuracy beats immediacy.
///
/// Resampling on the audio path was measurably worse, not just more code. A resampler is a
/// polyphase FIR holding some 30 input frames in its delay line, and it only gives them
/// back when the stream is declared finished. A drain loop can never declare that — more
/// audio is always coming — so every pass abandons the filter's contents, and every pass
/// that hands the converter more input than one call consumes loses the remainder outright.
/// Measured on a one-second 48 kHz tone: 6% of the recording gone. Over a finished file,
/// with a real end of stream, the same conversion is frame-exact.
actor TrackRecorder {
    /// Seconds the producer may run unattended before the ring buffer overflows. Far more
    /// than the drain interval needs, and about a megabyte at 48 kHz.
    private static let ringHeadroom = 4.0

    /// Samples moved from the ring to disk per pass.
    private static let drainChunkFrames = 8_192

    private static let drainInterval = Duration.milliseconds(50)

    /// What a finished track amounts to. `peakAmplitude` is the number that decides whether
    /// a recording is real: a valid file of the right duration containing pure silence is
    /// this project's signature failure, and only a peak measurement tells the two apart.
    struct Summary: Sendable {
        let label: String
        let url: URL
        let sampleRate: Double
        let frameCount: Int
        let peakAmplitude: Float
        let droppedSampleCount: Int

        /// Mach host time of the track's first sample. Tracks are merged against each
        /// other on this, not on the moment the user pressed record.
        let firstSampleHostTime: UInt64?

        var duration: TimeInterval { Double(frameCount) / sampleRate }
        var isSilent: Bool { peakAmplitude < 0.001 }

        /// The device delivered samples outside `[-1, 1]`. Float32 audio is not clamped by
        /// the hardware, so an input gain set too high arrives intact and is only truncated
        /// when it reaches Int16 — measured at 2.03 with a microphone next to loud
        /// speakers. The result is a distorted recording, which ASR handles badly, so it is
        /// worth saying out loud rather than leaving to be noticed by ear.
        var isClipped: Bool { peakAmplitude > 1 }

        /// Within a decibel of full scale. Not clipped yet, and one loud sentence away from
        /// it — measured at -0.6 dBFS on a normal speaking voice, which the clipping check
        /// above passes silently.
        var isTooLoud: Bool { peakAmplitude >= 0.891 }
    }

    let label: String
    let url: URL
    let sampleRate: Double

    /// The producer's handle. `nonisolated` because an audio callback cannot await.
    nonisolated let input: TrackInput

    private let writer: WAVWriter
    private var floatScratch: [Float]
    private var intScratch: [Int16]
    private var peak: Float = 0
    private var drainTask: Task<Void, Never>?
    private var isFinished = false

    enum Failure: Error, LocalizedError {
        case unsupportedSourceFormat(sampleRate: Double)

        var errorDescription: String? {
            switch self {
            case .unsupportedSourceFormat(let sampleRate):
                "The audio source reported an unusable sample rate (\(sampleRate) Hz)."
            }
        }
    }

    /// - Parameter sampleRate: the rate the callback actually delivers, read from the device
    ///   rather than assumed. Assuming it is the mistake that yields a file of the right
    ///   length playing back at the wrong speed.
    init(label: String, url: URL, sampleRate: Double) throws {
        guard sampleRate > 0 else { throw Failure.unsupportedSourceFormat(sampleRate: sampleRate) }

        self.label = label
        self.url = url
        self.sampleRate = sampleRate
        self.input = TrackInput(ringCapacity: Int(sampleRate * Self.ringHeadroom))
        self.floatScratch = [Float](repeating: 0, count: Self.drainChunkFrames)
        self.intScratch = [Int16](repeating: 0, count: Self.drainChunkFrames)
        // Int16 at the device's rate, not Float32: it is the format every downstream tool
        // reads without argument, and 16 bits is some 90 dB of headroom below anything a
        // meeting recording resolves.
        self.writer = try WAVWriter(url: url, sampleRate: Int(sampleRate.rounded()), channelCount: 1)
    }

    /// Starts draining. Safe to call before the producer has delivered anything.
    func start() {
        guard drainTask == nil, !isFinished else { return }
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.drainInterval)
                await self?.drain()
            }
        }
    }

    /// Stops draining, flushes whatever the producer left behind, and closes the file.
    ///
    /// The caller must have stopped the producer first: anything written after this point
    /// stays in the ring buffer and never reaches disk.
    func finish() async -> Summary {
        if let drainTask {
            drainTask.cancel()
            await drainTask.value
        }
        drainTask = nil

        drain()
        isFinished = true
        do {
            try writer.finish()
        } catch {
            AppLog.capture.error(
                "\(self.label, privacy: .public): could not finalize the WAV header: \(error.localizedDescription, privacy: .public)"
            )
        }

        return Summary(
            label: label,
            url: url,
            sampleRate: sampleRate,
            frameCount: writer.frameCount,
            peakAmplitude: peak,
            droppedSampleCount: input.droppedSampleCount,
            firstSampleHostTime: input.firstSampleHostTime
        )
    }

    /// Peak so far, for a level meter while recording.
    var currentPeak: Float { peak }

    private func drain() {
        guard !isFinished else { return }
        let capacity = floatScratch.count

        while true {
            let read = floatScratch.withUnsafeMutableBufferPointer {
                input.ring.read(into: $0.baseAddress!, count: capacity)
            }
            guard read > 0 else { return }

            for index in 0..<read {
                let sample = floatScratch[index]
                peak = max(peak, abs(sample))
                intScratch[index] = Self.int16(from: sample)
            }

            do {
                try intScratch.withUnsafeBufferPointer {
                    try writer.append(UnsafeBufferPointer(start: $0.baseAddress!, count: read))
                }
            } catch {
                AppLog.capture.error(
                    "\(self.label, privacy: .public): could not write samples: \(error.localizedDescription, privacy: .public)"
                )
                return
            }

            // A short read means the ring is empty; the rest arrives on the next pass.
            if read < capacity { return }
        }
    }

    /// Float32 in `[-1, 1]` to Int16.
    ///
    /// Scaled by 32767 rather than 32768 so a full-scale sample cannot wrap round to the
    /// most negative value, which is heard as a click exactly where the audio was loudest.
    private static func int16(from sample: Float) -> Int16 {
        Int16((min(max(sample, -1), 1) * 32_767).rounded())
    }
}
