import Foundation
import Observation

/// Drives a recording from the UI's point of view.
///
/// Stage 0 establishes the state machine and the session directory. Attaching the actual
/// microphone and system-audio capture happens in stage 1, at the marked points below.
@MainActor
@Observable
final class RecordingController {
    enum State: Equatable {
        case idle
        case recording(RecordingSession)
        case failed(String)
    }

    private(set) var state: State = .idle
    let permissions: PermissionManager

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
            stop()
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
            // Stage 1 starts the microphone engine and the system-audio process tap here,
            // writing to session.microphoneTrackURL and session.systemTrackURL.
            state = .recording(session)
            AppLog.capture.info("recording started in \(session.directory.path, privacy: .public)")
        } catch {
            AppLog.capture.error("could not create the session directory: \(error.localizedDescription, privacy: .public)")
            state = .failed("Could not create the recording folder: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let session = currentSession else { return }
        // Stage 1 stops both capture streams and finalizes the two WAV files here.
        AppLog.capture.info("recording stopped after \(Date().timeIntervalSince(session.startedAt), format: .fixed(precision: 1)) s")
        state = .idle
    }
}
