import Foundation
import Observation
import TalkloomCore

protocol MicrophoneCapturing: Sendable {
    func begin(writingTo url: URL, voiceProcessing: Bool) async throws -> CaptureRun
    func monitorFirstSample(_ handler: @escaping @Sendable (UInt64) -> Void) async
    func observeRuntimeEvents(
        _ handler: @escaping @Sendable (CaptureRuntimeEvent) -> Void
    ) async
    func restart(
        after event: CaptureRuntimeEvent,
        writingTo nextSegmentURL: URL
    ) async throws -> CaptureRestartResult
    func reconfigure(
        run: CaptureRun,
        writingTo nextSegmentURL: URL,
        voiceProcessing: Bool
    ) async throws -> CaptureRestartResult
    func finishSession() async -> [TrackRecorder.Completion]
}

protocol SystemAudioCapturing: Sendable {
    func begin(writingTo url: URL) async throws -> CaptureRun
    func verifySignal() async throws -> Bool
    func monitorFirstSample(_ handler: @escaping @Sendable (UInt64) -> Void) async
    func observeRuntimeEvents(
        _ handler: @escaping @Sendable (CaptureRuntimeEvent) -> Void
    ) async
    func restart(
        after event: CaptureRuntimeEvent,
        writingTo nextSegmentURL: URL
    ) async throws -> CaptureRestartResult
    func finishSession() async -> [TrackRecorder.Completion]
}

/// Drives one recording: starts both paths, keeps them alive, and writes what happened.
///
/// What is *true* about a recording lives in `ActiveSession`, in `TalkloomCore`, where it
/// can be tested without hardware. What lives here is everything that cannot move: the order
/// the two paths are started in, the awaits on the capture actors, the manifest, and the state
/// the menu reads.
@MainActor
@Observable
final class RecordingController {
    struct RecordingResult {
        let session: RecordingSession
        let microphone: [TrackRecorder.Summary]
        let systemAudio: [TrackRecorder.Summary]
        let warning: String?
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

    var lastMicrophoneTrack: TrackRecorder.Summary? { previousRecording?.microphone.last }
    var lastSystemTrack: TrackRecorder.Summary? { previousRecording?.systemAudio.last }

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
                let run = try await systemAudio.begin(writingTo: created.systemTrackURL)
                systemStarted = true
                _ = updateStartingSession(created) { $0[.systemAudio] = .recording(run) }
                await monitorFirstSample(
                    .systemAudio,
                    for: created,
                    file: created.systemTrackURL.lastPathComponent)
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
                    $0[.systemAudio] = .unavailable(error.localizedDescription)
                    $0.warning = message
                }
                AppLog.capture.error(
                    "system audio capture did not start: \(error.localizedDescription, privacy: .public)"
                )
            }

            let microphoneRun = try await microphone.begin(
                writingTo: created.microphoneTrackURL,
                voiceProcessing: systemVerified
            )
            _ = updateStartingSession(created) {
                $0[.microphone] = .recording(microphoneRun)
                $0.microphoneUsesVoiceProcessing = systemVerified
                $0.systemAudioIsVerified = systemVerified
            }
            if await finishStartupFailureIfNeeded(for: created) { return }
            await monitorFirstSample(
                .microphone,
                for: created,
                file: created.microphoneTrackURL.lastPathComponent)
            if await finishStartupFailureIfNeeded(for: created) { return }
            guard updateStartingSession(created, { $0.phase = .recording }) else { return }

            await observeRuntimeEvents(for: created)
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
            _ = await microphone.finishSession()
            if systemStarted { _ = await systemAudio.finishSession() }
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

    /// Applies a transition to a session that is recording, and publishes it only if the
    /// transition actually happened.
    ///
    /// Every one of these runs after an await, by which time the session may have stopped,
    /// been replaced, or moved past the state the transition was decided in. The guard is the
    /// same every time, which is exactly why it is written once.
    @discardableResult
    private func updateRecordingSession(
        _ session: RecordingSession,
        _ update: (inout ActiveSession) -> Bool
    ) -> Bool {
        guard case .active(var active) = state, active.session == session,
            active.phase == .recording
        else { return false }
        guard update(&active) else { return false }
        state = .active(active)
        return true
    }

    /// The live state of a session that is still recording, or `nil` if it no longer is.
    private func recordingSession(_ session: RecordingSession) -> ActiveSession? {
        guard case .active(let active) = state, active.session == session,
            active.phase == .recording
        else { return nil }
        return active
    }

    private static let unverifiedSystemAudioWarning =
        "System audio could not be verified, so the microphone was recorded without echo cancellation to preserve both sides of the meeting."

    private static let restartAttemptLimit = 3

    // MARK: - Talking to the two capture paths

    private func monitorFirstSample(
        _ path: TrackSource,
        for session: RecordingSession,
        file: String
    ) async {
        let handler: @Sendable (UInt64) -> Void = { [weak self] hostTime in
            Task { @MainActor [weak self] in
                await self?.checkpointFirstSample(
                    file: file,
                    hostTime: hostTime,
                    for: session)
            }
        }
        switch path {
        case .microphone: await microphone.monitorFirstSample(handler)
        case .systemAudio: await systemAudio.monitorFirstSample(handler)
        }
    }

    private func restartCapture(
        _ path: TrackSource,
        after event: CaptureRuntimeEvent,
        writingTo url: URL
    ) async throws -> CaptureRestartResult {
        switch path {
        case .microphone: try await microphone.restart(after: event, writingTo: url)
        case .systemAudio: try await systemAudio.restart(after: event, writingTo: url)
        }
    }

    private func observeRuntimeEvents(for session: RecordingSession) async {
        await microphone.observeRuntimeEvents { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleRuntimeEvent(event, on: .microphone, for: session)
            }
        }
        guard isRecording(session) else { return }
        await systemAudio.observeRuntimeEvents { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleRuntimeEvent(event, on: .systemAudio, for: session)
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

    // MARK: - Keeping a path alive

    private func handleRuntimeEvent(
        _ event: CaptureRuntimeEvent,
        on path: TrackSource,
        for session: RecordingSession
    ) async {
        guard let active = recordingSession(session), active.isCurrent(event, on: path) else {
            return
        }

        if path == .systemAudio {
            // Whatever happens next, the system track has stopped being evidence that the
            // remote side is recorded anywhere, so echo cancellation has stopped being safe.
            updateRecordingSession(session) {
                $0.systemAudioIsVerified = false
                return true
            }
        }

        if event.retryability == .terminal {
            await markUnavailable(path, event.message, for: session)
            return
        }
        await restart(path, after: event, for: session)
    }

    /// Rebuilds a failed path, up to a fixed number of attempts, and gives up loudly.
    ///
    /// A replacement always gets a new master segment rather than appending to the one that
    /// failed: the wall-clock interval between them is missing from the recording, and the
    /// manifest states it rather than silently closing the gap.
    private func restart(
        _ path: TrackSource,
        after event: CaptureRuntimeEvent,
        for session: RecordingSession
    ) async {
        guard let active = recordingSession(session),
            let failedRun = active[path].run, failedRun.id == event.runID
        else { return }
        let nextURL = session.trackURL(for: path, segmentIndex: failedRun.segmentIndex + 1)

        for attempt in 1...Self.restartAttemptLimit {
            guard
                updateRecordingSession(
                    session,
                    {
                        $0.beginRestart(
                            path, runID: event.runID, attempt: attempt, reason: event.message)
                    })
            else { return }

            do {
                switch try await restartCapture(path, after: event, writingTo: nextURL) {
                case .stale:
                    return
                case .restarted(let run):
                    await publishRestart(
                        path, oldRunID: event.runID, newRun: run, writingTo: nextURL,
                        for: session)
                    return
                }
            } catch {
                if attempt == Self.restartAttemptLimit {
                    await markUnavailable(
                        path,
                        "\(event.message) Restart failed: \(error.localizedDescription)",
                        for: session)
                    return
                }
                await Task.yield()
            }
        }
    }

    /// What each path does with a replacement that started.
    ///
    /// This is the one place the two genuinely differ: a microphone segment is usable the
    /// moment it runs, while a system segment has to prove it carries signal before the
    /// microphone is allowed to subtract that same signal from its own track.
    private func publishRestart(
        _ path: TrackSource,
        oldRunID: UUID,
        newRun: CaptureRun,
        writingTo nextURL: URL,
        for session: RecordingSession
    ) async {
        switch path {
        case .microphone:
            guard
                updateRecordingSession(
                    session,
                    {
                        $0.completeRestart(
                            path,
                            oldRunID: oldRunID,
                            newRun: newRun,
                            warning:
                                "Microphone capture was interrupted and restored; its missing interval is stored as silence."
                        )
                    })
            else { return }
            await monitorFirstSample(path, for: session, file: nextURL.lastPathComponent)
            await disableEchoCancellationIfNeeded(for: session)

        case .systemAudio:
            guard
                updateRecordingSession(
                    session,
                    {
                        $0.beginVerification(path, oldRunID: oldRunID, newRun: newRun)
                    })
            else { return }
            await monitorFirstSample(path, for: session, file: nextURL.lastPathComponent)
            await verifyRestartedSystemAudio(newRun, for: session)
        }
    }

    private func verifyRestartedSystemAudio(
        _ run: CaptureRun,
        for session: RecordingSession
    ) async {
        let verificationFailure: String?
        do {
            verificationFailure =
                try await systemAudio.verifySignal()
                ? nil : "The restarted system audio path did not carry its verification signal."
        } catch {
            verificationFailure =
                "The restarted system audio path could not be verified: \(error.localizedDescription)"
        }

        let verified = updateRecordingSession(session) { active in
            guard active[.systemAudio] == .verifying(run) else { return false }
            active[.systemAudio] = .recording(run)
            active.systemAudioIsVerified = verificationFailure == nil
            if let verificationFailure {
                active.appendWarning(verificationFailure)
            } else {
                active.appendWarning(
                    "System audio was interrupted and restored; its missing interval is stored as silence."
                )
            }
            return true
        }
        guard verified else { return }
        if verificationFailure == nil { permissions.markSystemAudioWorking() }
        await disableEchoCancellationIfNeeded(for: session)
    }

    /// Rebuilds the microphone without echo cancellation once the system track stops being
    /// able to justify it.
    ///
    /// Cancellation removes the other participants from the microphone track. That is only
    /// safe while something else is recording them; when it is not, keeping the speakers in
    /// the microphone is the difference between a degraded recording and half a meeting.
    private func disableEchoCancellationIfNeeded(for session: RecordingSession) async {
        guard let active = recordingSession(session),
            active.microphoneUsesVoiceProcessing,
            case .recording(let run) = active[.microphone],
            !active.systemAudioIsVerified,
            active.systemVerificationIsSettled
        else { return }

        let nextURL = session.trackURL(for: .microphone, segmentIndex: run.segmentIndex + 1)
        updateRecordingSession(session) {
            $0[.microphone] = .restarting(
                runID: run.id,
                attempt: 1,
                reason: "system audio is no longer verified")
            return true
        }

        do {
            switch try await microphone.reconfigure(
                run: run,
                writingTo: nextURL,
                voiceProcessing: false)
            {
            case .stale:
                return
            case .restarted(let newRun):
                guard
                    updateRecordingSession(
                        session,
                        { active in
                            guard case .restarting(let runID, _, _) = active[.microphone],
                                runID == run.id
                            else { return false }
                            active[.microphone] = .recording(newRun)
                            active.microphoneUsesVoiceProcessing = false
                            active.appendWarning(
                                "The microphone was restarted without echo cancellation to preserve remote audio while system capture is unverified."
                            )
                            return true
                        })
                else { return }
                await monitorFirstSample(
                    .microphone, for: session, file: nextURL.lastPathComponent)
            }
        } catch {
            await markUnavailable(
                .microphone,
                "The microphone could not be restarted without echo cancellation: \(error.localizedDescription)",
                for: session)
        }
    }

    private func markUnavailable(
        _ path: TrackSource,
        _ reason: String,
        for session: RecordingSession
    ) async {
        let message = "\(Self.pathName(path)) capture could not be restored: \(reason)"
        guard
            updateRecordingSession(
                session,
                {
                    $0.markUnavailable(path, message); return true
                })
        else { return }
        if path == .systemAudio { await disableEchoCancellationIfNeeded(for: session) }
        await finishIfNoPathRemains(for: session)
    }

    private static func pathName(_ path: TrackSource) -> String {
        switch path {
        case .microphone: "Microphone"
        case .systemAudio: "System audio"
        }
    }

    private func finishIfNoPathRemains(for session: RecordingSession) async {
        guard let active = recordingSession(session), let lost = active.lostEveryPath else {
            return
        }
        await finish(
            session: session,
            failure: "\(lost.microphone) \(lost.systemAudio)")
    }

    private func finish(session: RecordingSession, failure: String?) async {
        guard case .active(var active) = state, active.session == session else { return }
        active.markStopping()
        state = .active(active)

        async let microphoneTrack = microphone.finishSession()
        async let systemTrack = systemAudio.finishSession()
        let tracks = await (microphoneTrack, systemTrack)
        let result = RecordingResult(
            session: session,
            microphone: tracks.0.map(\.summary),
            systemAudio: tracks.1.map(\.summary),
            warning: active.warning
        )
        if result.systemAudio.contains(where: { !$0.isSilent }) {
            permissions.markSystemAudioWorking()
        }

        AppLog.capture.info(
            "recording stopped after \(Date().timeIntervalSince(session.startedAt), format: .fixed(precision: 1), privacy: .public) s"
        )
        logTrackOffset(in: result)
        let completions = tracks.0 + tracks.1
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
        guard let microphoneStart = recording.microphone.first?.firstSampleHostTime,
            let systemStart = recording.systemAudio.first?.firstSampleHostTime
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
