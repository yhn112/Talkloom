import AVFoundation
import Foundation
import Testing

@testable import Transcriber

/// The first suite written against Swift Testing rather than XCTest.
///
/// The reason is the header table below. Under XCTest the fixed fields of a WAV header were
/// a dozen assertions inside one test, so a wrong byte rate reported as "testHeader failed"
/// and the field had to be found by reading the source. As arguments to a parameterized
/// test each field is its own case, named in the report.
///
/// New tests are written this way; the XCTest suites stay as they are until some other
/// change brings them into a diff. Both frameworks run side by side in this target.
@Suite("WAV writer")
final class WAVWriterTests {
    private let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "WAVWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ name: String) -> URL { directory.appending(path: name) }

    private func write(_ samples: [Int16], to url: URL, sampleRate: Int = 16_000) throws {
        let writer = try WAVWriter(url: url, sampleRate: sampleRate, channelCount: 1)
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish()
    }

    /// Reads a little-endian unsigned field of `byteCount` bytes, which is every numeric
    /// field a WAV header has.
    private func integer(_ data: Data, at offset: Int, byteCount: Int) -> UInt32 {
        data[offset..<(offset + byteCount)]
            .reversed()
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// One fixed field of the canonical header: 16 kHz mono 16-bit PCM.
    struct HeaderField: Sendable, CustomTestStringConvertible {
        let name: String
        let offset: Int
        let byteCount: Int
        let value: UInt32

        var testDescription: String { name }
    }

    @Test(
        "header field",
        arguments: [
            HeaderField(name: "fmt chunk size", offset: 16, byteCount: 4, value: 16),
            HeaderField(name: "WAVE_FORMAT_PCM", offset: 20, byteCount: 2, value: 1),
            HeaderField(name: "channel count", offset: 22, byteCount: 2, value: 1),
            HeaderField(name: "sample rate", offset: 24, byteCount: 4, value: 16_000),
            HeaderField(name: "byte rate", offset: 28, byteCount: 4, value: 32_000),
            HeaderField(name: "block align", offset: 32, byteCount: 2, value: 2),
            HeaderField(name: "bits per sample", offset: 34, byteCount: 2, value: 16),
        ]
    )
    func headerField(_ field: HeaderField) throws {
        let file = url("mono.wav")
        try write([Int16](repeating: 0, count: 800), to: file)

        let data = try Data(contentsOf: file)
        #expect(integer(data, at: field.offset, byteCount: field.byteCount) == field.value)
    }

    /// The four-character chunk tags, in the order a reader walks them.
    @Test("chunk tag", arguments: [(0, "RIFF"), (8, "WAVE"), (12, "fmt "), (36, "data")])
    func chunkTag(offset: Int, tag: String) throws {
        let file = url("tags.wav")
        try write([Int16](repeating: 0, count: 800), to: file)

        let data = try Data(contentsOf: file)
        #expect(String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii) == tag)
    }

    @Test("the file is a 44-byte header followed by the samples")
    func fileLength() throws {
        let file = url("length.wav")
        try write([Int16](repeating: 0, count: 800), to: file)

        #expect(try Data(contentsOf: file).count == 44 + 800 * 2)
    }

    /// The sizes are the whole reason `finish` exists: a file whose header still says zero
    /// bytes opens fine and plays as silence, which is the exact failure this project keeps
    /// having to rule out.
    @Test("finish patches the sizes into the header")
    func finishPatchesTheSizes() throws {
        let file = url("sizes.wav")
        try write([Int16](repeating: 1, count: 1234), to: file)

        let data = try Data(contentsOf: file)
        #expect(integer(data, at: 4, byteCount: 4) == UInt32(36 + 1234 * 2), "RIFF size")
        #expect(integer(data, at: 40, byteCount: 4) == UInt32(1234 * 2), "data size")
    }

    @Test("the header is incomplete until finish runs")
    func headerIsIncompleteUntilFinish() throws {
        let file = url("unfinished.wav")
        let writer = try WAVWriter(url: file, sampleRate: 16_000, channelCount: 1)
        try [Int16](repeating: 3, count: 100).withUnsafeBufferPointer { try writer.append($0) }

        let data = try Data(contentsOf: file)
        #expect(data.count == 44 + 200, "samples reach disk as they are recorded")
        #expect(integer(data, at: 40, byteCount: 4) == 0, "the size is only known at the end")

        try writer.finish()
    }

    @Test("frame count tracks what was written")
    func frameCountTracksWhatWasWritten() throws {
        let writer = try WAVWriter(url: url("frames.wav"), sampleRate: 16_000, channelCount: 1)
        #expect(writer.frameCount == 0)

        try [Int16](repeating: 0, count: 480).withUnsafeBufferPointer { try writer.append($0) }
        try [Int16](repeating: 0, count: 320).withUnsafeBufferPointer { try writer.append($0) }
        #expect(writer.frameCount == 800)

        try writer.finish()
    }

    /// Everything downstream — Whisper, `afconvert`, `ffmpeg`, the audio-doctor scripts —
    /// reads these files through some decoder. Reading the result back with AVFoundation
    /// checks the header against a real one instead of against our own idea of it.
    @Test("AVFoundation reads the samples back unchanged")
    func avFoundationRoundTrip() throws {
        let file = url("roundtrip.wav")
        // A quarter second of a 440 Hz tone: an amplitude that a peak measurement can see.
        let sampleRate = 16_000
        let samples = (0..<(sampleRate / 4)).map { index -> Int16 in
            let phase = 2 * Double.pi * 440 * Double(index) / Double(sampleRate)
            return Int16(sin(phase) * 16_000)
        }
        try write(samples, to: file, sampleRate: sampleRate)

        let audioFile = try AVAudioFile(forReading: file)
        #expect(audioFile.fileFormat.sampleRate == 16_000)
        #expect(audioFile.fileFormat.channelCount == 1)
        #expect(audioFile.length == AVAudioFramePosition(samples.count))

        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                interleaved: false))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        try audioFile.read(into: buffer)
        #expect(buffer.frameLength == AVAudioFrameCount(samples.count))

        let decoded = try #require(buffer.floatChannelData)[0]
        let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(decoded[$1])) }
        #expect(abs(peak - 16_000 / 32_768) < 0.001, "peak amplitude survives the round trip")
    }
}
