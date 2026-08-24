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
    private(set) var lastSystemTrack: TrackRecorder.Summary?

    /// Something went wrong that did not stop the recording — in practice, system audio
    /// failing while the microphone kept going.
    private(set) var warning: String?

    let permissions: PermissionManager
    private let microphone = MicrophoneCapture()
    private let systemAudio = SystemAudioCapture()

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
            lastSystemTrack = nil
            warning = nil

            // System audio starts first, and whether it worked decides how the microphone
            // is configured. Echo cancellation removes the other participants from the
            // microphone track; that is only safe because the tap is recording them
            // separately. With no system track, cancelling them would erase them from the
            // only recording there is — so the microphone keeps the speaker bleed instead,
            // echo and all. A doubled transcript is recoverable; a missing one is not.
            var systemAudioIsRecording = false
            do {
                try await systemAudio.start(writingTo: session.systemTrackURL)
                permissions.setSystemAudio(.granted)
                systemAudioIsRecording = true
            } catch {
                permissions.setSystemAudio(.denied)
                warning =
                    "Recording the microphone only, with echo cancellation off so the other participants are still captured through the speakers. \(error.localizedDescription)"
                AppLog.capture.error(
                    "system audio capture did not start: \(error.localizedDescription, privacy: .public)"
                )
            }

            try await microphone.start(
                writingTo: session.microphoneTrackURL,
                voiceProcessing: systemAudioIsRecording
            )

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
        lastSystemTrack = await systemAudio.stop()

        AppLog.capture.info(
            "recording stopped after \(Date().timeIntervalSince(session.startedAt), format: .fixed(precision: 1), privacy: .public) s"
        )
        logTrackOffset()
        writeManifest(for: session)
    }

    /// How far apart the two tracks actually started.
    ///
    /// The streams do not begin together — the tap waits for a process to make a sound —
    /// so segments have to be merged on this offset rather than on a shared zero.
    var trackOffset: TimeInterval? {
        guard let microphoneStart = lastMicrophoneTrack?.firstSampleHostTime,
            let systemStart = lastSystemTrack?.firstSampleHostTime
        else { return nil }
        return HostTime.seconds(from: microphoneStart, to: systemStart)
    }

    private func writeManifest(for session: RecordingSession) {
        let summaries = [lastMicrophoneTrack, lastSystemTrack].compactMap { $0 }
        guard !summaries.isEmpty else { return }
        do {
            try RecordingManifest(startedAt: session.startedAt, summaries: summaries).write(to: session.directory)
        } catch {
            AppLog.capture.error(
                "could not write the session manifest: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func logTrackOffset() {
        guard let offset = trackOffset else { return }
        AppLog.capture.notice(
            "system audio started \(offset, format: .fixed(precision: 3), privacy: .public) s after the microphone"
        )
    }
}
