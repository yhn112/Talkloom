import Darwin
import Foundation
import TranscriberCore

/// A short output signal that proves the running process tap carries samples before echo
/// cancellation is allowed to remove the speakers from the microphone track.
///
/// A separate `afplay` process emits it because capturing this app's own output would not
/// prove that the tap can read the other processes which carry a remote meeting. The
/// frequency is above the canonical 16 kHz ASR format's Nyquist limit, so offline conversion
/// filters it out. Its level is intentionally low, and the fades avoid clicks.
enum SystemAudioProbe {
    static let signalThreshold: Float = 0.005
    static let observationTimeout = Duration.milliseconds(250)

    private static let sampleRate = 48_000
    private static let amplitude: Float = 0.02
    private static let duration = 0.1
    private static let frequency = 18_000.0
    private static let fadeDuration = 0.005
    private static let playbackTimeout = Duration.seconds(2)
    private static let terminationGracePeriod = Duration.milliseconds(200)

    enum Failure: Error, LocalizedError {
        case playbackFailed(Int32)
        case playbackTimedOut

        var errorDescription: String? {
            switch self {
            case .playbackFailed(let status):
                "The system audio verification probe exited with status \(status)."
            case .playbackTimedOut:
                "The system audio verification probe did not finish."
            }
        }
    }

    static func play() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appending(
            path: "Transcriber-system-probe-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let writer = try WAVWriter(url: fileURL, sampleRate: sampleRate, channelCount: 1)
        let frameCount = Int(Double(sampleRate) * duration)
        let fadeFrames = max(1, Int(Double(sampleRate) * fadeDuration))
        var samples = [Int16](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let fadeIn = min(1, Float(frame) / Float(fadeFrames))
            let fadeOut = min(1, Float(frameCount - frame - 1) / Float(fadeFrames))
            let phase = 2 * Double.pi * frequency * Double(frame) / Double(sampleRate)
            samples[frame] = Int16(
                (amplitude * min(fadeIn, fadeOut) * Float(sin(phase)) * 32_767).rounded())
        }
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        try writer.finish()

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [fileURL.path]

        try player.run()
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: playbackTimeout)
            while player.isRunning, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard !player.isRunning else { throw Failure.playbackTimedOut }
            guard player.terminationStatus == 0 else {
                throw Failure.playbackFailed(player.terminationStatus)
            }
        } catch {
            await terminate(player)
            throw error
        }
    }

    /// Stops and reaps a timed-out or cancelled helper without blocking the capture actor.
    private static func terminate(_ player: Process) async {
        await Task.detached {
            guard player.isRunning else { return }
            player.terminate()

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: terminationGracePeriod)
            while player.isRunning, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if player.isRunning {
                _ = Darwin.kill(player.processIdentifier, SIGKILL)
            }
            // SIGKILL cannot be handled or ignored. Reaping here keeps the temporary WAV
            // alive until the helper has released it and prevents a zombie child.
            waitUntilExit(player)
        }.value
    }

    private static func waitUntilExit(_ player: Process) {
        player.waitUntilExit()
    }
}
