import Foundation
import Testing

/// The parent of every suite that touches real audio hardware.
///
/// It exists for two reasons that XCTest gave for free and Swift Testing does not.
///
/// `.serialized` is the important one. Swift Testing runs tests in parallel by default,
/// and two captures running at once produce garbage in both recordings — the microphone,
/// the process tap and the default output device are exclusive resources here. Applying
/// the trait to this suite serializes every descendant, across files.
///
/// `.enabled(if:)` replaces the `XCTSkipUnless` that each suite used to repeat: these
/// tests need a microphone, working speakers, the two permissions, and they make audible
/// noise, so they are opt-in.
///
/// `.timeLimit` turns a wedged audio stack into a failure instead of a run that never
/// ends. Observed: with capture interrupted mid-recording, the next test stopped producing
/// output entirely and had to be killed by hand. The longest test here — the ducking table,
/// nine measurements of four seconds each — needs about a minute, so five is generous.
///
///     xcodebuild -project Transcriber.xcodeproj -scheme TranscriberDeviceTests \
///       -derivedDataPath build test
///
/// The scheme sets `TRANSCRIBER_DEVICE_TESTS`, because xcodebuild does not forward the
/// shell's environment to the test host.
@Suite(
    "device",
    .serialized,
    .timeLimit(.minutes(5)),
    .enabled(
        if: ProcessInfo.processInfo.environment["TRANSCRIBER_DEVICE_TESTS"] == "1",
        "set TRANSCRIBER_DEVICE_TESTS=1, or use the TranscriberDeviceTests scheme"
    )
)
struct DeviceTests {
    /// A directory that lives for one suite instance and is removed with it.
    static func makeDirectory(_ label: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Speaks through the default output device so a microphone or a tap has something to
    /// hear. Ten words at 180 words per minute outlasts the four-second recordings below.
    static func speak() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", "180", "One two three four five six seven eight nine ten"]
        try? process.run()
        return process
    }
}
