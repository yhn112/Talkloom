import Foundation
import Observation

/// Drives a recording from the UI's point of view.
@MainActor
@Observable
final class RecordingController {
    enum State: Equatable {
        case idle
        case recording(RecordingSession)
        case failed(String)
    }

    private(set) var state: State = .idle

    /// What the last recording produced. Kept on screen after stopping because the peak
    /// amplitude is the only thing that distinguishes a real recording from a valid file
    /// full of silence, and finding that out a day later is too late.
    private(set) var lastMicrophoneTrack: TrackRecorder.Summary?

    let permissions: PermissionManager
    private let microphone = MicrophoneCapture()

    init(permissions: PermissionManager = PermissionManager()) {
        self.permissions = permissions
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var currentSession: RecordingSession? {
        if case .recording(let session) = state { return session }
        return nil
    }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    func toggle() async {
        if isRecording {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        await permissions.requestMicrophone()
        guard permissions.microphone.isUsable else {
            let message = "Microphone access is required. Grant it in System Settings › Privacy & Security › Microphone."
            AppLog.capture.error("refusing to start: microphone permission not granted")
            state = .failed(message)
            return
        }

        do {
            let session = try RecordingSession.create()
            lastMicrophoneTrack = nil
            // Stage 1 starts the system-audio process tap here, writing to
            // session.systemTrackURL.
            try await microphone.start(writingTo: session.microphoneTrackURL)
            state = .recording(session)
            AppLog.capture.info("recording started in \(session.directory.path, privacy: .public)")
        } catch {
            AppLog.capture.error("could not start recording: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard let session = currentSession else { return }
        state = .idle
        lastMicrophoneTrack = await microphone.stop()
        AppLog.capture.info(
            "recording stopped after \(Date().timeIntervalSince(session.startedAt), format: .fixed(precision: 1), privacy: .public) s"
        )
    }
}
