import Foundation
import Testing

@testable import TalkloomCore

/// The restart and degradation policy, tested as arithmetic.
///
/// These rules used to be reachable only through `RecordingController`, which meant reaching
/// them through two capture doubles, an actor hop and a real session directory — so most of
/// them were exercised only where a controller test happened to pass through. Here every
/// transition is one call, and the rows below are the cases that decide whether a meeting
/// survives a dead capture path.
@Suite("Active session state")
struct ActiveSessionTests {
    private func session() -> RecordingSession {
        RecordingSession(
            directory: URL(fileURLWithPath: "/tmp/does-not-need-to-exist"),
            startedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func recording(_ path: TrackSource, segmentIndex: Int = 0) -> (
        ActiveSession, CaptureRun
    ) {
        var active = ActiveSession(session: session())
        active.phase = .recording
        let run = CaptureRun(id: UUID(), segmentIndex: segmentIndex)
        active[path] = .recording(run)
        return (active, run)
    }

    @Test("a path nobody has touched is pending, not absent")
    func anUntouchedPathIsPending() {
        let active = ActiveSession(session: session())
        #expect(active[.microphone] == .pending)
        #expect(active[.systemAudio] == .pending)
        #expect(active.microphone == active[.microphone])
        #expect(active.systemAudio == active[.systemAudio])
    }

    /// A runtime event names the generation it came from. Only the generation that is still
    /// current may act on one: a report from a producer that has already been replaced would
    /// restart the healthy path that took its place.
    @Test(
        "only the running generation owns a runtime event",
        arguments: [
            (state: ActiveSession.TrackState.pending, isCurrent: false),
            (state: .restarting(runID: UUID(), attempt: 1, reason: "gone"), isCurrent: false),
            (state: .stopping, isCurrent: false),
            (state: .unavailable("gone"), isCurrent: false),
        ] as [(state: ActiveSession.TrackState, isCurrent: Bool)])
    func onlyTheRunningGenerationOwnsAnEvent(state: ActiveSession.TrackState, isCurrent: Bool) {
        let run = CaptureRun(id: UUID(), segmentIndex: 0)
        var active = ActiveSession(session: session())
        active[.systemAudio] = state
        let event = CaptureRuntimeEvent(runID: run.id, message: "x", retryability: .restartable)
        #expect(active.isCurrent(event, on: .systemAudio) == isCurrent)
    }

    @Test("a recording or verifying generation owns its own event")
    func aLiveGenerationOwnsItsEvent() {
        let run = CaptureRun(id: UUID(), segmentIndex: 0)
        let event = CaptureRuntimeEvent(runID: run.id, message: "x", retryability: .restartable)
        for state in [ActiveSession.TrackState.recording(run), .verifying(run)] {
            var active = ActiveSession(session: session())
            active[.systemAudio] = state
            #expect(active.isCurrent(event, on: .systemAudio))
            #expect(active[.systemAudio].run == run)
        }
    }

    /// Attempt numbers have to follow each other. Two restarts racing on the same generation
    /// would otherwise both believe they own the replacement.
    @Test("a restart attempt is accepted only when it follows the one before it")
    func restartAttemptsMustFollowEachOther() {
        var (active, run) = recording(.systemAudio)

        let skipsAhead = active.beginRestart(.systemAudio, runID: run.id, attempt: 2, reason: "r")
        #expect(skipsAhead == false)
        let first = active.beginRestart(.systemAudio, runID: run.id, attempt: 1, reason: "r")
        #expect(first)
        #expect(active[.systemAudio] == .restarting(runID: run.id, attempt: 1, reason: "r"))

        let skipsAgain = active.beginRestart(.systemAudio, runID: run.id, attempt: 3, reason: "r")
        #expect(skipsAgain == false)
        let second = active.beginRestart(.systemAudio, runID: run.id, attempt: 2, reason: "r")
        #expect(second)

        let otherGeneration = active.beginRestart(
            .systemAudio, runID: UUID(), attempt: 3, reason: "r")
        #expect(otherGeneration == false)
    }

    @Test(
        "a path that is not running cannot be restarted",
        arguments: [
            ActiveSession.TrackState.pending,
            .stopping,
            .unavailable("gone"),
        ])
    func aPathThatIsNotRunningCannotBeRestarted(state: ActiveSession.TrackState) {
        var active = ActiveSession(session: session())
        active[.microphone] = state
        let began = active.beginRestart(.microphone, runID: UUID(), attempt: 1, reason: "r")
        #expect(began == false)
        #expect(active[.microphone] == state)
    }

    @Test("a replacement is published only against the generation it replaces")
    func aReplacementIsPublishedOnlyAgainstItsPredecessor() {
        var (active, run) = recording(.microphone)
        let replacement = CaptureRun(id: UUID(), segmentIndex: 1)
        let began = active.beginRestart(.microphone, runID: run.id, attempt: 1, reason: "r")
        #expect(began)

        let wrongPredecessor = active.completeRestart(
            .microphone, oldRunID: UUID(), newRun: replacement, warning: "w")
        #expect(wrongPredecessor == false)
        let published = active.completeRestart(
            .microphone, oldRunID: run.id, newRun: replacement, warning: "restored")
        #expect(published)
        #expect(active[.microphone] == .recording(replacement))
        #expect(active.warning == "restored")
    }

    /// A restarted system path is not usable until it proves it carries signal: the microphone
    /// is subtracting that same signal from its own track.
    @Test("a restarted system path is published as verifying, not as recording")
    func aRestartedSystemPathMustVerify() {
        var (active, run) = recording(.systemAudio)
        let replacement = CaptureRun(id: UUID(), segmentIndex: 1)
        let began = active.beginRestart(.systemAudio, runID: run.id, attempt: 1, reason: "r")
        #expect(began)
        let verifying = active.beginVerification(
            .systemAudio, oldRunID: run.id, newRun: replacement)
        #expect(verifying)
        #expect(active[.systemAudio] == .verifying(replacement))
        #expect(active.systemVerificationIsSettled == false)
    }

    @Test(
        "the microphone waits for the system path to stop being undecided",
        arguments: [
            (
                state: ActiveSession.TrackState.recording(CaptureRun(id: UUID(), segmentIndex: 0)),
                settled: true
            ),
            (state: .unavailable("gone"), settled: true),
            (state: .pending, settled: false),
            (state: .restarting(runID: UUID(), attempt: 1, reason: "r"), settled: false),
            (state: .verifying(CaptureRun(id: UUID(), segmentIndex: 1)), settled: false),
            (state: .stopping, settled: false),
        ] as [(state: ActiveSession.TrackState, settled: Bool)])
    func systemVerificationSettles(state: ActiveSession.TrackState, settled: Bool) {
        var active = ActiveSession(session: session())
        active[.systemAudio] = state
        #expect(active.systemVerificationIsSettled == settled)
    }

    /// Losing the system path is what withdraws the microphone's permission to cancel echo.
    @Test("giving up on the system path withdraws its verification")
    func losingTheSystemPathWithdrawsVerification() {
        var (active, _) = recording(.systemAudio)
        active.systemAudioIsVerified = true
        active.markUnavailable(.systemAudio, "the tap died")
        #expect(active.systemAudioIsVerified == false)
        #expect(active[.systemAudio] == .unavailable("the tap died"))
        #expect(active.warning == "the tap died")
    }

    @Test("giving up on the microphone leaves the system verification alone")
    func losingTheMicrophoneLeavesVerificationAlone() {
        var (active, _) = recording(.microphone)
        active.systemAudioIsVerified = true
        active.markUnavailable(.microphone, "no input device")
        #expect(active.systemAudioIsVerified)
    }

    @Test("a session is lost only once both paths are")
    func aSessionIsLostOnlyOnceBothPathsAre() {
        var active = ActiveSession(session: session())
        active[.microphone] = .recording(CaptureRun(id: UUID(), segmentIndex: 0))
        active.markUnavailable(.systemAudio, "system gone")
        #expect(active.lostEveryPath == nil)

        active.markUnavailable(.microphone, "microphone gone")
        let lost = active.lostEveryPath
        #expect(lost?.microphone == "microphone gone")
        #expect(lost?.systemAudio == "system gone")
    }

    /// A degraded session usually has more than one thing to say, and the second does not
    /// make the first untrue — but the same sentence arriving twice is one fact.
    @Test("warnings accumulate without repeating themselves")
    func warningsAccumulateWithoutRepeating() {
        var active = ActiveSession(session: session())
        active.appendWarning("the tap died")
        active.appendWarning("echo cancellation is off")
        active.appendWarning("the tap died")
        #expect(active.warning == "the tap died echo cancellation is off")
    }

    @Test("stopping takes every path with it")
    func stoppingTakesEveryPathWithIt() {
        var (active, _) = recording(.microphone)
        active[.systemAudio] = .verifying(CaptureRun(id: UUID(), segmentIndex: 1))
        active.markStopping()
        #expect(active.phase == .stopping)
        for path in TrackSource.allCases {
            #expect(active[path] == .stopping)
        }
    }
}
