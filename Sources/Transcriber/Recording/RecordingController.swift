import Foundation
import Observation
import TranscriberCore

protocol MicrophoneCapturing: Sendable {
    func begin(writingTo url: URL, voiceProcessing: Bool) async throws
    func monitorRuntimeFailures(_ handler: @escaping @Sendable (String) -> Void) async
    func end() async -> TrackRecorder.Completion?
}

protocol SystemAudioCapturing: Sendable {
    func begin(writingTo url: URL) async throws
    func monitorRuntimeFailures(_ handler: @escaping @Sendable (String) -> Void) async
    func end() async -> TrackRecorder.Completion?
}

extension MicrophoneCapture: MicrophoneCapturing {
    func begin(writingTo url: URL, voiceProcessing: Bool) async throws {
        _ = try await start(writingTo: url, voiceProcessing: voiceProcessing)
    }

    func end() async -> TrackRecorder.Completion? { await stop() }
}

extension SystemAudioCapture: SystemAudioCapturing {
    func begin(writingTo url: URL) async throws {
        _ = try await start(writingTo: url)
    }

    func end() async -> TrackRecorder.Completion? { await stop() }
}

/// Owns the complete lifecycle of one recording. UI state and cleanup eligibility are the
/// same state machine, so a failed start cannot leave a hidden capture path behind.
@MainActor
@Observable
final class RecordingController {
    enum State: Equatable {
        case idle
        case starting(RecordingSession?)
        case recording(RecordingSession)
        case stopping(RecordingSession)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastMicrophoneTrack: TrackRecorder.Summary?
    private(set) var lastSystemTrack: TrackRecorder.Summary?
    private(set) var warning: String?

    /// Sessions the previous run never finished, repaired on the way in.
    private(set) var recoveredSessions: [SessionRecovery.Outcome] = []
    private var hasRecovered = false

    let permissions: PermissionManager
    private let microphone: any MicrophoneCapturing
    private let systemAudio: any SystemAudioCapturing
    private let sessionRoot: URL?

    init(
        permissions: PermissionManager = PermissionManager(),
        sessionRoot: URL? = nil,
        microphone: any MicrophoneCapturing = MicrophoneCapture(),
        systemAudio: any SystemAudioCapturing = SystemAudioCapture()
    ) {
        self.permissions = permissions
        self.sessionRoot = sessionRoot
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    var isRecording: Bool {
        switch state {
        case .starting(let session): session != nil
        case .recording, .stopping: true
        default: false
        }
    }

    var isTransitioning: Bool {
        switch state {
        case .starting, .stopping: true
        default: false
        }
    }

    var currentSession: RecordingSession? {
        switch state {
        case .starting(let session): session
        case .recording(let session), .stopping(let session): session
        default: nil
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// Repairs whatever the previous run left half-written.
    ///
    /// A session killed mid-recording leaves WAV headers still claiming zero bytes, so a
    /// full meeting reads as an empty file everywhere. The repair is keyed on the manifest
    /// saying `recording`, runs once per launch, and touches nothing this run created.
    ///
    /// It runs when the menu first opens rather than from `init`: the menu is the only way
    /// to reach this app at all, so nothing can be recorded before it, and a recording that
    /// waits a few seconds longer to become readable costs nothing.
    func recoverInterruptedSessions() async {
        guard !hasRecovered else { return }
        hasRecovered = true
        guard let root = sessionRoot ?? (try? RecordingSession.defaultRoot()) else { return }

        // Off the main actor: this reads every session directory the user has ever recorded.
        let outcomes = await Task.detached { SessionRecovery.recoverInterrupted(in: root) }.value
        guard !outcomes.isEmpty else { return }

        recoveredSessions = outcomes
        for outcome in outcomes {
            AppLog.app.notice(
                "repaired the interrupted session \(outcome.directory.lastPathComponent, privacy: .public): \(outcome.repairedTracks.joined(separator: ", "), privacy: .public)"
            )
            if let failure = outcome.failure {
                AppLog.app.error(
                    "\(outcome.directory.lastPathComponent, privacy: .public) could not be fully recovered: \(failure, privacy: .public)"
                )
            }
        }
    }

    func toggle() async {
        switch state {
        case .idle, .failed:
            await start()
        case .recording:
            await stop()
        case .starting, .stopping:
            return
        }
    }

    func start() async {
        guard state == .idle || isFailed else { return }
        state = .starting(nil)

        await permissions.requestMicrophone()
        guard permissions.microphone.isUsable else {
            fail(
                "Microphone access is required. Grant it in System Settings › Privacy & Security › Microphone."
            )
            return
        }

        var session: RecordingSession?
        var systemStarted = false
        do {
            let created = try RecordingSession.create(root: sessionRoot)
            session = created
            state = .starting(created)
            lastMicrophoneTrack = nil
            lastSystemTrack = nil
            warning = nil
            permissions.beginSystemAudioCheck()

            do {
                try await systemAudio.begin(writingTo: created.systemTrackURL)
                systemStarted = true
            } catch {
                warning =
                    "Recording the microphone only, with echo cancellation off so the other participants are still captured through the speakers. \(error.localizedDescription)"
                AppLog.capture.error(
                    "system audio capture did not start: \(error.localizedDescription, privacy: .public)"
                )
            }

            try await microphone.begin(
                writingTo: created.microphoneTrackURL,
                voiceProcessing: systemStarted
            )

            state = .recording(created)
            await armRuntimeFailureMonitoring()
            guard state == .recording(created) else { return }
            AppLog.capture.info("recording started in \(created.directory.path, privacy: .public)")
        } catch {
            // End both paths even when only one reached its running state. The capture
            // contracts make ending a path that never started a no-op.
            _ = await microphone.end()
            if systemStarted { _ = await systemAudio.end() }
            if let session { try? FileManager.default.removeItem(at: session.directory) }
            fail(error.localizedDescription)
        }
    }

    func stop() async {
        guard case .recording(let session) = state else { return }
        await finish(session: session, failure: nil)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func armRuntimeFailureMonitoring() async {
        await microphone.monitorRuntimeFailures { [weak self] message in
            Task { @MainActor [weak self] in
                await self?.handleRuntimeFailure("Microphone capture stopped: \(message)")
            }
        }
        await systemAudio.monitorRuntimeFailures { [weak self] message in
            Task { @MainActor [weak self] in
                await self?.handleRuntimeFailure("System audio capture stopped: \(message)")
            }
        }
    }

    private func handleRuntimeFailure(_ message: String) async {
        guard case .recording(let session) = state else { return }
        await finish(session: session, failure: message)
    }

    private func finish(session: RecordingSession, failure: String?) async {
        state = .stopping(session)

        async let microphoneTrack = microphone.end()
        async let systemTrack = systemAudio.end()
        let tracks = await (microphoneTrack, systemTrack)
        lastMicrophoneTrack = tracks.0?.summary
        lastSystemTrack = tracks.1?.summary
        if let system = lastSystemTrack, !system.isSilent {
            permissions.markSystemAudioWorking()
        }

        AppLog.capture.info(
            "recording stopped after \(Date().timeIntervalSince(session.startedAt), format: .fixed(precision: 1), privacy: .public) s"
        )
        logTrackOffset()
        let completions = [tracks.0, tracks.1].compactMap { $0 }
        let finalFailure = failure ?? completions.compactMap(\.failure).first?.localizedDescription
        let manifestFailure = writeManifest(
            for: session,
            completions: completions,
            failure: finalFailure,
            warning: warning
        )

        // A session whose manifest could not be replaced is not a session that stopped
        // successfully, whatever the tracks did: the audio is finalized on disk while the
        // only description of it still says `recording` and carries no track timestamps.
        // Reporting that as a clean stop hides the one thing the reader of that directory
        // would need to know.
        switch (finalFailure, manifestFailure) {
        case (nil, nil):
            state = .idle
        case (let trackFailure?, nil):
            fail(trackFailure)
        case (nil, let manifestFailure?):
            fail(
                "The tracks were saved in \(session.directory.lastPathComponent), but the session could not be described on disk: \(manifestFailure)"
            )
        case (let trackFailure?, let manifestFailure?):
            fail(
                "\(trackFailure) The session could not be described on disk either: \(manifestFailure)"
            )
        }
    }

    private func fail(_ message: String) {
        AppLog.capture.error("recording failed: \(message, privacy: .public)")
        state = .failed(message)
    }

    var trackOffset: TimeInterval? {
        guard let microphoneStart = lastMicrophoneTrack?.firstSampleHostTime,
            let systemStart = lastSystemTrack?.firstSampleHostTime
        else { return nil }
        return HostTime.seconds(from: microphoneStart, to: systemStart)
    }

    /// Replaces the in-progress manifest with the finished one.
    ///
    /// - Returns: `nil` when the session now describes itself on disk, or why it does not.
    private func writeManifest(
        for session: RecordingSession,
        completions: [TrackRecorder.Completion],
        failure: String?,
        warning: String?
    ) -> String? {
        do {
            try RecordingManifest(
                startedAt: session.startedAt,
                reports: completions.map(\.report),
                failure: failure,
                warning: warning
            )
            .write(to: session.directory)
            return nil
        } catch {
            AppLog.capture.error(
                "could not write the session manifest: \(error.localizedDescription, privacy: .public)"
            )
            return error.localizedDescription
        }
    }

    private func logTrackOffset() {
        guard let offset = trackOffset else { return }
        AppLog.capture.notice(
            "system audio started \(offset, format: .fixed(precision: 3), privacy: .public) s after the microphone"
        )
    }
}
