import Foundation

/// Appends 16-bit PCM samples to a `.wav` file.
///
/// The file is written as it is recorded rather than assembled at the end, so a crash
/// mid-meeting costs the tail of the recording instead of all of it. Sizes in the header
/// are only known once recording stops, so `init` lays down a placeholder header and
/// `finish` rewrites it in place.
///
/// Not thread-safe and deliberately not `Sendable`: it belongs to the single consumer that
/// drains a ring buffer. Nothing here may be called from an audio callback — it does file
/// I/O on every call.
final class WAVWriter {
    /// Byte length of a canonical PCM WAV header: RIFF chunk, `fmt ` chunk, `data` header.
    private static let headerByteCount = 44

    let url: URL
    let sampleRate: Int
    let channelCount: Int

    /// Frames written so far. Duration in seconds is this divided by the sample rate.
    private(set) var frameCount = 0

    private var handle: FileHandle?

    init(url: URL, sampleRate: Int, channelCount: Int) throws {
        precondition(sampleRate > 0 && channelCount > 0)
        self.url = url
        self.sampleRate = sampleRate
        self.channelCount = channelCount

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channelCount: channelCount, dataByteCount: 0))
        self.handle = handle
    }

    /// Appends interleaved samples.
    ///
    /// WAV stores samples little-endian, which is what `Int16` already is on arm64, so the
    /// buffer goes to disk unchanged.
    func append(_ samples: UnsafeBufferPointer<Int16>) throws {
        guard let handle, !samples.isEmpty else { return }
        try handle.write(contentsOf: Data(buffer: samples))
        frameCount += samples.count / channelCount
    }

    /// Rewrites the header with the real sizes and closes the file.
    ///
    /// Until this runs the file declares zero-length audio, so every player and every
    /// decoder reads it as empty. Call it on every exit path, including failures.
    func finish() throws {
        guard let handle else { return }
        self.handle = nil
        let dataByteCount = frameCount * channelCount * MemoryLayout<Int16>.size
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channelCount: channelCount, dataByteCount: dataByteCount))
        try handle.close()
    }

    deinit {
        // A dropped writer would otherwise leave a file that claims to contain no audio.
        try? finish()
    }

    private static func header(sampleRate: Int, channelCount: Int, dataByteCount: Int) -> Data {
        let bitsPerSample = 16
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign

        var data = Data(capacity: headerByteCount)
        data.append(ascii: "RIFF")
        data.append(littleEndian: UInt32(headerByteCount - 8 + dataByteCount))
        data.append(ascii: "WAVE")
        data.append(ascii: "fmt ")
        data.append(littleEndian: UInt32(16))            // size of the PCM fmt chunk body
        data.append(littleEndian: UInt16(1))             // WAVE_FORMAT_PCM
        data.append(littleEndian: UInt16(channelCount))
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(byteRate))
        data.append(littleEndian: UInt16(blockAlign))
        data.append(littleEndian: UInt16(bitsPerSample))
        data.append(ascii: "data")
        data.append(littleEndian: UInt32(dataByteCount))
        return data
    }
}

private extension Data {
    mutating func append(ascii text: StaticString) {
        append(UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
    }

    mutating func append(littleEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(littleEndian value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
