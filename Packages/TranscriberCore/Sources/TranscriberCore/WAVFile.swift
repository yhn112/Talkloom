import Foundation

/// Reading and repairing the header `WAVWriter` lays down.
///
/// A recording that ends with the process still alive gets its sizes rewritten by
/// `WAVWriter.finish`. One that ends with a crash, a kill, or a logout does not: the header
/// on disk still declares zero bytes of audio, so every player, `afconvert`, and
/// `AVAudioFile` reads a full recording as an empty file. The samples are there — only the
/// four bytes that say how many are wrong, and the file's own length says what they should
/// have been.
public enum WAVFile {
    /// The canonical 44-byte PCM header this project writes: RIFF, `fmt `, `data`, with no
    /// extra chunks in between. Anything else is somebody else's file.
    static let headerByteCount = 44

    public struct Info: Equatable, Sendable {
        public let sampleRate: Int
        public let channelCount: Int

        /// Frames the file actually contains, derived from its length rather than from the
        /// header, which is the field a crash leaves stale.
        public let frameCount: Int

        /// Whether the header disagreed with the file and had to be rewritten.
        public let wasRepaired: Bool
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case truncated(name: String)
        case unsupportedLayout(name: String)

        public var errorDescription: String? {
            switch self {
            case .truncated(let name):
                "\(name) is too short to contain a WAV header."
            case .unsupportedLayout(let name):
                "\(name) is not a canonical 16-bit PCM WAV file written by this app."
            }
        }
    }

    /// Makes the header agree with the file, and reports what the file turned out to hold.
    ///
    /// A partially written final frame — a write torn by the crash itself — is left outside
    /// the `data` chunk rather than rounded up into it, so the last frame a reader sees is
    /// one that was written whole.
    @discardableResult
    public static func repairSizes(at url: URL) throws -> Info {
        let name = url.lastPathComponent
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        guard let header = try handle.read(upToCount: headerByteCount),
            header.count == headerByteCount
        else { throw Failure.truncated(name: name) }

        guard header.matches("RIFF", at: 0), header.matches("WAVE", at: 8),
            header.matches("fmt ", at: 12), header.matches("data", at: 36),
            header.integer(at: 20) as UInt16 == 1,
            header.integer(at: 34) as UInt16 == 16
        else { throw Failure.unsupportedLayout(name: name) }

        let channelCount = Int(header.integer(at: 22) as UInt16)
        let sampleRate = Int(header.integer(at: 24) as UInt32)
        let declaredDataByteCount = Int(header.integer(at: 40) as UInt32)
        guard channelCount > 0, sampleRate > 0 else {
            throw Failure.unsupportedLayout(name: name)
        }

        let blockAlign = channelCount * MemoryLayout<Int16>.size
        let fileByteCount = Int(try handle.seekToEnd())
        let frameCount = max(0, fileByteCount - headerByteCount) / blockAlign
        let dataByteCount = frameCount * blockAlign

        guard dataByteCount != declaredDataByteCount else {
            return Info(
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameCount: frameCount,
                wasRepaired: false
            )
        }

        try handle.seek(toOffset: 4)
        try handle.write(
            contentsOf: Data(littleEndian: UInt32(headerByteCount - 8 + dataByteCount)))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Data(littleEndian: UInt32(dataByteCount)))
        return Info(
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            wasRepaired: true
        )
    }
}

extension Data {
    fileprivate func matches(_ ascii: String, at offset: Int) -> Bool {
        self[startIndex + offset..<startIndex + offset + ascii.utf8.count].elementsEqual(
            ascii.utf8)
    }

    /// Reads a little-endian integer without assuming the buffer is aligned for it:
    /// most significant byte last, accumulated a byte at a time.
    fileprivate func integer<Value: FixedWidthInteger & UnsignedInteger>(at offset: Int) -> Value {
        let start = startIndex + offset
        return self[start..<start + MemoryLayout<Value>.size]
            .reversed()
            .reduce(Value.zero) { ($0 << 8) | Value($1) }
    }

    fileprivate init<Value: FixedWidthInteger>(littleEndian value: Value) {
        self = Swift.withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
