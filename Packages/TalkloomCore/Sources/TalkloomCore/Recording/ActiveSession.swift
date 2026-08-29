import Foundation

/// What one recording is doing right now: the phase the session is in, and the state of each
/// capture path inside it.
///
/// This is the whole restart and degradation policy, and it lives here rather than in the
/// controller because none of it needs hardware. Every transition below is a pure function of
/// the current state and one event, so the rules that decide whether a session survives a dead
/// tap can be table-tested in a second, with no microphone, no actors and no doubles.
/// `RecordingController` keeps what genuinely cannot move: the awaits, the effects on the
/// capture actors, and the UI.
///
/// Paths are held in a dictionary keyed by `TrackSource` rather than in two fields. The two
/// were symmetric, and the symmetry was being written out by hand — every guard, every
/// transition and every failure path existed twice, once per path, with the differences that
/// mattered buried among the differences that did not.
public struct ActiveSession: Equatable, Sendable {
    /// Where the session as a whole is.
    ///
    /// `failingStartup` exists because a start cannot always be abandoned where it fails: a
    /// capture actor may be suspended inside `begin`, before it has published the resource a
    /// teardown would have to release. The failure is recorded here and acted on once that
    /// owner returns.
    public enum Phase: Equatable, Sendable {
        case starting
        case failingStartup(String)
        case recording
        case stopping
    }

    /// Where one capture path is.
    public enum TrackState: Equatable, Sendable {
        case pending
        case recording(CaptureRun)
        case restarting(runID: UUID, attempt: Int, reason: String)
        case verifying(CaptureRun)
        case stopping
        case unavailable(String)

        /// The generation a runtime event can still be about.
        ///
        /// A path being rebuilt has none: the report that started the rebuild is the last
        /// thing its predecessor is allowed to say, and acting on a later one would restart
        /// the healthy generation that replaced it.
        public var run: CaptureRun? {
            switch self {
            case .recording(let run), .verifying(let run): run
            case .pending, .restarting, .stopping, .unavailable: nil
            }
        }
    }

    public let session: RecordingSession
    public var phase: Phase = .starting
    public private(set) var tracks: [TrackSource: TrackState] = [:]

    /// Whether the microphone is currently cancelling echo, and whether the system track has
    /// earned that. The pair is what decides if the microphone has to be rebuilt: cancellation
    /// removes the other participants, and that is only safe while something else is recording
    /// them.
    public var microphoneUsesVoiceProcessing = false
    public var systemAudioIsVerified = false

    public var warning: String?

    public init(session: RecordingSession) {
        self.session = session
    }

    /// A path that has never been touched reads as `pending` rather than as absent: the two
    /// mean the same thing and only one of them needs handling everywhere.
    public subscript(path: TrackSource) -> TrackState {
        get { tracks[path] ?? .pending }
        set { tracks[path] = newValue }
    }

    public var microphone: TrackState { self[.microphone] }
    public var systemAudio: TrackState { self[.systemAudio] }

    /// Whether `event` is about the generation this path is still running.
    public func isCurrent(_ event: CaptureRuntimeEvent, on path: TrackSource) -> Bool {
        self[path].run?.id == event.runID
    }

    // MARK: - Transitions

    /// Marks a path as being rebuilt.
    ///
    /// The attempt number has to follow the one before it. Two restarts of the same generation
    /// racing each other would otherwise both believe they own the replacement, and the loser
    /// would go on to overwrite the winner's state with a run that no longer exists.
    public mutating func beginRestart(
        _ path: TrackSource,
        runID: UUID,
        attempt: Int,
        reason: String
    ) -> Bool {
        let follows: Bool
        switch self[path] {
        case .recording(let run), .verifying(let run):
            follows = run.id == runID && attempt == 1
        case .restarting(let currentRunID, let currentAttempt, _):
            follows = currentRunID == runID && attempt == currentAttempt + 1
        case .pending, .stopping, .unavailable:
            follows = false
        }
        guard follows else { return false }
        self[path] = .restarting(runID: runID, attempt: attempt, reason: reason)
        return true
    }

    /// Publishes a replacement generation as the path's current one.
    public mutating func completeRestart(
        _ path: TrackSource,
        oldRunID: UUID,
        newRun: CaptureRun,
        warning: String
    ) -> Bool {
        guard case .restarting(let runID, _, _) = self[path], runID == oldRunID else {
            return false
        }
        self[path] = .recording(newRun)
        appendWarning(warning)
        return true
    }

    /// Publishes a replacement generation that still has to prove it carries signal.
    ///
    /// A restarted system path is not usable until it does: echo cancellation on the other
    /// track is subtracting the very audio this one is supposed to be keeping.
    public mutating func beginVerification(
        _ path: TrackSource,
        oldRunID: UUID,
        newRun: CaptureRun
    ) -> Bool {
        guard case .restarting(let runID, _, _) = self[path], runID == oldRunID else {
            return false
        }
        self[path] = .verifying(newRun)
        return true
    }

    /// Gives up on a path for the rest of the session, and says so in the warning the user
    /// sees. The other path keeps recording: half a meeting is not nothing.
    public mutating func markUnavailable(_ path: TrackSource, _ message: String) {
        self[path] = .unavailable(message)
        if path == .systemAudio { systemAudioIsVerified = false }
        appendWarning(message)
    }

    public mutating func markStopping() {
        phase = .stopping
        for path in TrackSource.allCases { self[path] = .stopping }
    }

    /// Whether the system path has finished deciding what it is. While it is being rebuilt or
    /// verified, the microphone must not act on its state: the answer is still coming.
    public var systemVerificationIsSettled: Bool {
        switch self[.systemAudio] {
        case .recording, .unavailable: true
        case .pending, .restarting, .verifying, .stopping: false
        }
    }

    /// The failures of both paths, once neither has anything left to record.
    public var lostEveryPath: (microphone: String, systemAudio: String)? {
        guard case .unavailable(let microphone) = self[.microphone],
            case .unavailable(let systemAudio) = self[.systemAudio]
        else { return nil }
        return (microphone, systemAudio)
    }

    /// Warnings accumulate rather than replace. A session that lost the tap and then had to
    /// drop echo cancellation has two things to tell the user, and the second does not make
    /// the first untrue — but the same warning arriving twice is one fact, not two.
    public mutating func appendWarning(_ warning: String) {
        guard let current = self.warning else {
            self.warning = warning
            return
        }
        guard !current.contains(warning) else { return }
        self.warning = "\(current) \(warning)"
    }
}
