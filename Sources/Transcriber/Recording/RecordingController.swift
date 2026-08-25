import Foundation
import Observation
import TranscriberCore

protocol MicrophoneCapturing: Sendable {
    func begin(writingTo url: URL, voiceProcessing: Bool) async throws
    func monitorFirstSample(_ handler: @escaping @Sendable (UInt64) -> Void) async
    func monitorRuntimeFailures(_ handler: @escaping @Sendable (String) -> Void) async
    func end() async -> TrackRecorder.Completion?
}

protocol SystemAudioCapturing: Sendable {
    func begin(writingTo url: URL) async throws
    func verifySignal() async throws -> Bool
    func monitorFirstSample(_ handler: @escaping @Sendable (UInt64) -> Void) async
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
    struct RecordingResult {
        let session: RecordingSession
        let microphone: TrackRecorder.Summary?
        let systemAudio: TrackRecorder.Summary?
        let warning: String?
    }

    struct ActiveSession {
        enum Phase: Equatable {
            case starting
            case failingStartup(String)
            case recording
            case stopping
        }

        enum TrackState: Equatable {
            case pending
            case recording
            case stopping
            case unavailable(String)
        }

        let session: RecordingSession
        var phase: Phase = .starting
        var microphone: TrackState = .pending
        var systemAudio: TrackState = .pending
        var warning: String?
    }

    struct FailureState {
        let message: String
        let recording: RecordingResult?
    }

    enum State {
        case idle(RecordingResult?)
        case preparing(RecordingResult?)
        case active(ActiveSession)
        case failed(FailureState)
    }

    private(set) var state: State = .idle(nil)

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
        if case .active = state { return true }
        return false
    }

    var isTransitioning: Bool {
        switch state {
        case .preparing: true
        case .active(let active): active.phase != .recording
        case .idle, .failed: false
        }
    }

    var currentSession: RecordingSession? {
        guard case .active(let active) = state else { return nil }
        return active.session
    }

    var errorMessage: String? {
        if case .failed(let failure) = state { return failure.message }
        if case .active(let active) = state,
            case .failingStartup(let message) = active.phase
        {
            return message
        }
        return nil
    }

    var lastMicrophoneTrack: TrackRecorder.Summary? { previousRecording?.microphone }
    var lastSystemTrack: TrackRecorder.Summary? { previousRecording?.systemAudio }

    var warning: String? {
        if case .active(let active) = state { return active.warning }
        return previousRecording?.warning
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
        case .active(let active) where active.phase == .recording:
            await stop()
        case .preparing, .active:
            return
        }
    }

    func start() async {
        guard canStart else { return }
        state = .preparing(previousRecording)

        await permissions.requestMicrophone()
        guard permissions.microphone.isUsable else {
            fail(
                "Microphone access is required. Grant it in System Settings › Privacy & Security › Microphone."
            )
            return
        }

        var session: RecordingSession?
        var systemStarted = false
        var systemVerified = false
        do {
            let created = try RecordingSession.create(root: sessionRoot)
            session = created
            state = .active(ActiveSession(session: created))
            permissions.beginSystemAudioCheck()

            do {
                try await systemAudio.begin(writingTo: created.systemTrackURL)
                systemStarted = true
                _ = updateStartingSession(created) { $0.systemAudio = .recording }
                await monitorSystemFirstSample(for: created)
                if await finishStartupFailureIfNeeded(for: created) { return }
                guard isStarting(created) else { return }

                do {
                    systemVerified = try await systemAudio.verifySignal()
                    if systemVerified {
                        permissions.markSystemAudioWorking()
                    } else {
                        _ = updateStartingSession(created) {
                            $0.warning = Self.unverifiedSystemAudioWarning
                        }
                        AppLog.capture.error(
                            "system audio capture did not carry the verification probe")
                    }
                } catch {
                    _ = updateStartingSession(created) {
                        $0.warning =
                            "\(Self.unverifiedSystemAudioWarning) \(error.localizedDescription)"
                    }
                    AppLog.capture.error(
                        "system audio verification failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
                if await finishStartupFailureIfNeeded(for: created) { return }
                guard isStarting(created) else { return }
            } catch {
                let message =
                    "Recording the microphone only, with echo cancellation off so the other participants are still captured through the speakers. \(error.localizedDescription)"
                _ = updateStartingSession(created) {
                    $0.systemAudio = .unavailable(error.localizedDescription)
                    $0.warning = message
                }
                AppLog.capture.error(
                    "system audio capture did not start: \(error.localizedDescription, privacy: .public)"
                )
            }

            try await microphone.begin(
                writingTo: created.microphoneTrackURL,
                voiceProcessing: systemVerified
            )
            _ = updateStartingSession(created) { $0.microphone = .recording }
            if await finishStartupFailureIfNeeded(for: created) { return }
            await monitorMicrophoneFirstSample(for: created)
            if await finishStartupFailureIfNeeded(for: created) { return }
            guard updateStartingSession(created, { $0.phase = .recording }) else { return }

            await armRuntimeFailureMonitoring(for: created)
            guard isRecording(created) else { return }
            AppLog.capture.info("recording started in \(created.directory.path, privacy: .public)")
        } catch {
            // A checkpoint failure may already be stopping this startup while one of the
            // capture actors finishes an awaited `begin`. That path owns cleanup and the
            // final manifest; it must not be overwritten by this task resuming later.
            if let session, await finishStartupFailureIfNeeded(for: session) { return }
            if let session, !isStarting(session) { return }
            // End both paths even when only one reached its running state. The capture
            // contracts make ending a path that never started a no-op.
            _ = await microphone.end()
            if systemStarted { _ = await systemAudio.end() }
            if let session { try? FileManager.default.removeItem(at: session.directory) }
            fail(error.localizedDescription)
        }
    }

    func stop() async {
        guard case .active(let active) = state, active.phase == .recording else { return }
        await finish(session: active.session, failure: nil)
    }

    private var previousRecording: RecordingResult? {
        switch state {
        case .idle(let recording), .preparing(let recording): recording
        case .failed(let failure): failure.recording
        case .active: nil
        }
    }

    private var canStart: Bool {
        switch state {
        case .idle, .failed: true
        case .preparing, .active: false
        }
    }

    private func isStarting(_ session: RecordingSession) -> Bool {
        guard case .active(let active) = state else { return false }
        return active.session == session && active.phase == .starting
    }

    private func isRecording(_ session: RecordingSession) -> Bool {
        guard case .active(let active) = state else { return false }
        return active.session == session && active.phase == .recording
    }

    @discardableResult
    private func updateStartingSession(
        _ session: RecordingSession,
        _ update: (inout ActiveSession) -> Void
    ) -> Bool {
        guard case .active(var active) = state, active.session == session,
            active.phase == .starting
        else { return false }
        update(&active)
        state = .active(active)
        return true
    }

    private static let unverifiedSystemAudioWarning =
        "System audio could not be verified, so the microphone was recorded without echo cancellation to preserve both sides of the meeting."

    private func monitorMicrophoneFirstSample(for session: RecordingSession) async {
        await microphone.monitorFirstSample { [weak self] hostTime in
            Task { @MainActor [weak self] in
                await self?.checkpointFirstSample(
                    file: session.microphoneTrackURL.lastPathComponent,
                    hostTime: hostTime,
                    for: session)
            }
        }
    }

    private func monitorSystemFirstSample(for session: RecordingSession) async {
        await systemAudio.monitorFirstSample { [weak self] hostTime in
            Task { @MainActor [weak self] in
                await self?.checkpointFirstSample(
                    file: session.systemTrackURL.lastPathComponent,
                    hostTime: hostTime,
                    for: session)
            }
        }
    }

    private func armRuntimeFailureMonitoring(for session: RecordingSession) async {
        await microphone.monitorRuntimeFailures { [weak self] message in
            Task { @MainActor [weak self] in
                await self?.handleRuntimeFailure(
                    "Microphone capture stopped: \(message)",
                    for: session)
            }
        }
        guard isRecording(session) else { return }
        await systemAudio.monitorRuntimeFailures { [weak self] message in
            Task { @MainActor [weak self] in
                await self?.handleRuntimeFailure(
                    "System audio capture stopped: \(message)",
                    for: session)
            }
        }
    }

    private func checkpointFirstSample(
        file: String,
        hostTime: UInt64,
        for session: RecordingSession
    ) async {
        guard case .active(let active) = state, active.session == session,
            active.phase == .starting || active.phase == .recording
        else { return }

        do {
            let manifestURL = session.directory.appending(path: RecordingManifest.fileName)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(
                RecordingManifest.self,
                from: Data(contentsOf: manifestURL))
            guard manifest.status == .recording else { return }
            try manifest.checkpointingFirstSample(file: file, hostTime: hostTime)
                .write(to: session.directory)
        } catch {
            await handleCheckpointFailure(
                for: session,
                "The session timeline could not be checkpointed: \(error.localizedDescription)")
        }
    }

    private func handleCheckpointFailure(for session: RecordingSession, _ message: String) async {
        guard case .active(var active) = state, active.session == session else { return }
        switch active.phase {
        case .starting:
            // A capture actor may currently be suspended inside `begin()`, before it has
            // published the resource that `end()` must tear down. Let that owner finish
            // startup, then the startup task calls `finishStartupFailureIfNeeded`.
            active.phase = .failingStartup(message)
            state = .active(active)
        case .recording:
            await finish(session: session, failure: message)
        case .failingStartup, .stopping:
            return
        }
    }

    private func finishStartupFailureIfNeeded(for session: RecordingSession) async -> Bool {
        guard case .active(let active) = state, active.session == session,
            case .failingStartup(let message) = active.phase
        else {
            return false
        }
        await finish(session: session, failure: message)
        return true
    }

    private func handleRuntimeFailure(_ message: String, for session: RecordingSession) async {
        guard case .active(let active) = state, active.session == session,
            active.phase == .recording
        else { return }
        await finish(session: session, failure: message)
    }

    private func finish(session: RecordingSession, failure: String?) async {
        guard case .active(var active) = state, active.session == session else { return }
        active.phase = .stopping
        if active.microphone == .recording { active.microphone = .stopping }
        if active.systemAudio == .recording { active.systemAudio = .stopping }
        state = .active(active)

        async let microphoneTrack = microphone.end()
        async let systemTrack = systemAudio.end()
        let tracks = await (microphoneTrack, systemTrack)
        let result = RecordingResult(
            session: session,
            microphone: tracks.0?.summary,
            systemAudio: tracks.1?.summary,
            warning: active.warning
        )
        if let system = result.systemAudio, !system.isSilent {
            permissions.markSystemAudioWorking()
        }

        AppLog.capture.info(
            "recording stopped after \(Date().timeIntervalSince(session.startedAt), format: .fixed(precision: 1), privacy: .public) s"
        )
        logTrackOffset(in: result)
        let completions = [tracks.0, tracks.1].compactMap { $0 }
        let finalFailure = failure ?? completions.compactMap(\.failure).first?.localizedDescription
        let manifestFailure = writeManifest(
            for: session,
            completions: completions,
            failure: finalFailure,
            warning: result.warning
        )

        // A session whose manifest could not be replaced is not a session that stopped
        // successfully, whatever the tracks did: the audio is finalized on disk while the
        // only description of it still says `recording` and carries no track timestamps.
        // Reporting that as a clean stop hides the one thing the reader of that directory
        // would need to know.
        switch (finalFailure, manifestFailure) {
        case (nil, nil):
            state = .idle(result)
        case (let trackFailure?, nil):
            fail(trackFailure, recording: result)
        case (nil, let manifestFailure?):
            fail(
                "The tracks were saved in \(session.directory.lastPathComponent), but the session could not be described on disk: \(manifestFailure)",
                recording: result
            )
        case (let trackFailure?, let manifestFailure?):
            fail(
                "\(trackFailure) The session could not be described on disk either: \(manifestFailure)",
                recording: result
            )
        }
    }

    private func fail(_ message: String, recording: RecordingResult? = nil) {
        AppLog.capture.error("recording failed: \(message, privacy: .public)")
        state = .failed(FailureState(message: message, recording: recording ?? previousRecording))
    }

    var trackOffset: TimeInterval? {
        guard let recording = previousRecording else { return nil }
        return trackOffset(in: recording)
    }

    private func trackOffset(in recording: RecordingResult) -> TimeInterval? {
        guard let microphoneStart = recording.microphone?.firstSampleHostTime,
            let systemStart = recording.systemAudio?.firstSampleHostTime
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

    private func logTrackOffset(in recording: RecordingResult) {
        guard let offset = trackOffset(in: recording) else { return }
        AppLog.capture.notice(
            "system audio started \(offset, format: .fixed(precision: 3), privacy: .public) s after the microphone"
        )
    }
}
