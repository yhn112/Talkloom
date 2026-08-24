import AVFoundation
import XCTest

@testable import Transcriber

final class WAVWriterTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/dev/null")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "WAVWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ name: String) -> URL { directory.appending(path: name) }

    private func write(_ samples: [Int16], to url: URL, sampleRate: Int = 16_000) throws {
        let writer = try WAVWriter(url: url, sampleRate: sampleRate, channelCount: 1)
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish()
    }

    private func field<T: FixedWidthInteger>(_ data: Data, at offset: Int, as type: T.Type) -> T {
        data.subdata(in: offset..<(offset + MemoryLayout<T>.size))
            .withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
    }

    func testHeaderDescribes16BitMonoPCM() throws {
        let file = url("mono.wav")
        try write([Int16](repeating: 0, count: 800), to: file)

        let data = try Data(contentsOf: file)
        XCTAssertEqual(data.count, 44 + 800 * 2)
        XCTAssertEqual(String(data: data.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.subdata(in: 12..<16), encoding: .ascii), "fmt ")
        XCTAssertEqual(field(data, at: 16, as: UInt32.self), 16)
        XCTAssertEqual(field(data, at: 20, as: UInt16.self), 1, "WAVE_FORMAT_PCM")
        XCTAssertEqual(field(data, at: 22, as: UInt16.self), 1, "mono")
        XCTAssertEqual(field(data, at: 24, as: UInt32.self), 16_000)
        XCTAssertEqual(field(data, at: 28, as: UInt32.self), 32_000, "byte rate")
        XCTAssertEqual(field(data, at: 32, as: UInt16.self), 2, "block align")
        XCTAssertEqual(field(data, at: 34, as: UInt16.self), 16, "bits per sample")
        XCTAssertEqual(String(data: data.subdata(in: 36..<40), encoding: .ascii), "data")
    }

    /// The sizes are the whole reason `finish` exists: a file whose header still says zero
    /// bytes opens fine and plays as silence, which is the exact failure this project keeps
    /// having to rule out.
    func testFinishPatchesTheSizesIntoTheHeader() throws {
        let file = url("sizes.wav")
        try write([Int16](repeating: 1, count: 1234), to: file)

        let data = try Data(contentsOf: file)
        XCTAssertEqual(field(data, at: 4, as: UInt32.self), UInt32(36 + 1234 * 2), "RIFF size")
        XCTAssertEqual(field(data, at: 40, as: UInt32.self), UInt32(1234 * 2), "data size")
    }

    func testHeaderIsIncompleteUntilFinishRuns() throws {
        let file = url("unfinished.wav")
        let writer = try WAVWriter(url: file, sampleRate: 16_000, channelCount: 1)
        try [Int16](repeating: 3, count: 100).withUnsafeBufferPointer { try writer.append($0) }

        let data = try Data(contentsOf: file)
        XCTAssertEqual(data.count, 44 + 200, "samples reach disk as they are recorded")
        XCTAssertEqual(field(data, at: 40, as: UInt32.self), 0, "the size is only known at the end")

        try writer.finish()
    }

    func testFrameCountTracksWhatWasWritten() throws {
        let writer = try WAVWriter(url: url("frames.wav"), sampleRate: 16_000, channelCount: 1)
        XCTAssertEqual(writer.frameCount, 0)

        try [Int16](repeating: 0, count: 480).withUnsafeBufferPointer { try writer.append($0) }
        try [Int16](repeating: 0, count: 320).withUnsafeBufferPointer { try writer.append($0) }
        XCTAssertEqual(writer.frameCount, 800)

        try writer.finish()
    }

    /// Everything downstream — Whisper, `afconvert`, `ffmpeg`, the audio-doctor scripts —
    /// reads these files through some decoder. Reading the result back with AVFoundation
    /// checks the header against a real one instead of against our own idea of it.
    func testAVFoundationReadsBackTheSamplesUnchanged() throws {
        let file = url("roundtrip.wav")
        // A quarter second of a 440 Hz tone: an amplitude that a peak measurement can see.
        let sampleRate = 16_000
        let samples = (0..<(sampleRate / 4)).map { index -> Int16 in
            let phase = 2 * Double.pi * 440 * Double(index) / Double(sampleRate)
            return Int16(sin(phase) * 16_000)
        }
        try write(samples, to: file, sampleRate: sampleRate)

        let audioFile = try AVAudioFile(forReading: file)
        XCTAssertEqual(audioFile.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(audioFile.fileFormat.channelCount, 1)
        XCTAssertEqual(audioFile.length, AVAudioFramePosition(samples.count))

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        try audioFile.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, AVAudioFrameCount(samples.count))

        let decoded = buffer.floatChannelData![0]
        let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(decoded[$1])) }
        XCTAssertEqual(
            peak, 16_000 / 32_768, accuracy: 0.001, "peak amplitude survives the round trip")
    }
}
