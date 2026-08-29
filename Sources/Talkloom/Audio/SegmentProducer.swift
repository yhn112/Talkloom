import Foundation
import TalkloomCore

/// What one generation of a capture path will actually deliver, read from the hardware
/// rather than assumed. Assuming here is what produces a valid file full of silence.
struct SegmentFormat: Sendable, Equatable {
    let sampleRate: Double
    let channelCount: UInt32
}

/// How a capture path names the tracks it writes and the log lines it emits.
struct CaptureTrackDescriptor: Sendable {
    /// The recorder's label, which reaches the manifest: `mic`, `system`.
    let trackLabel: String
    /// Prose for the log: `microphone`, `system audio`.
    let name: String
    let source: TrackSource
}

/// The physical half of one capture path: how a producer generation is acquired, attached to
/// a real-time input, watched, and released.
///
/// `TrackCapture` owns everything else — generations, restart, the interrupted-path handoff,
/// completions, and the session's end. Splitting it this way is what makes that lifecycle
/// exist once rather than twice; before it, the microphone and the process tap carried the
/// same state machine in two files that had already drifted apart in their guards.
///
/// Every requirement here is synchronous and runs inside `TrackCapture`'s isolation, so a
/// conformer's mutable state is protected by that actor and needs none of its own. The one
/// exception is what a conformer hands to the audio thread: a callback installed by `attach`
/// is bound by the real-time contract in `AGENTS.md` and may only copy into `TrackInput`.
/// `SendableMetatype` rather than `Sendable`: a producer instance is owned by one actor and
/// must never be shared, but `TrackCapture` is generic over it and needs its metatype to cross
/// into the tasks that report a failure.
protocol SegmentProducer: AnyObject, SendableMetatype {
    /// Everything about a generation the caller chooses rather than the hardware — echo
    /// cancellation, for instance. Carried through a restart so a replacement generation is
    /// configured like the one it replaces.
    associatedtype Options: Sendable

    /// The hardware one generation holds, and which `release` gives back.
    ///
    /// A reference type, and the producer keeps its own reference to every generation it
    /// hands out until releasing it succeeds. That is what makes the producer the single
    /// owner: a `TrackCapture` dropped mid-recording takes the producer with it, and the
    /// producer's own `deinit` is then the last chance to give the hardware back.
    associatedtype Generation: AnyObject

    /// Produced by `TrackCapture` itself: a path's hardware half is process-long-lived and
    /// takes no arguments, so the two are created together and stay together.
    init()

    var descriptor: CaptureTrackDescriptor { get }

    /// What the master written under these options actually contains.
    func content(for options: Options) -> TrackContent

    /// Take the hardware for one generation and report the format it will deliver.
    ///
    /// Throwing must leave nothing acquired: this is the one step with no `release` to
    /// follow it.
    func acquire(_ options: Options) throws -> (Generation, SegmentFormat)

    /// Give the generation the input to write into and start delivery. Throwing must leave
    /// `generation` in a state `release` can still take apart.
    func attach(_ generation: Generation, to input: TrackInput) throws

    /// Give back everything `acquire` took, in the order the objects depend on each other.
    ///
    /// Called on every exit path — rollback, restart, session end — and must tolerate a
    /// generation that was never attached. A conformer holding a resource the system refused
    /// to destroy keeps it and retries; reporting the failure and forgetting the handle is how
    /// an aggregate device outlives the process.
    func release(_ generation: Generation, context: String)

    /// Begin watching this generation for the failure this path actually has: a stalled tap,
    /// a device change under the engine.
    ///
    /// `report` is the only way a producer reaches the outside world. It is safe to call from
    /// any context, is ignored once the generation it belongs to is no longer current, and
    /// stops this watch as a side effect.
    func beginWatching(
        _ generation: Generation,
        input: TrackInput,
        report: @escaping @Sendable (String, CaptureRuntimeEvent.Retryability) -> Void
    )

    /// Stop the watch begun by `beginWatching`. Called before every teardown, and safe when
    /// no watch is running.
    func stopWatching()

    /// A last look at what this path's own diagnostics say about a finished segment, before
    /// it becomes a completion nobody can add to.
    func amend(
        _ completion: TrackRecorder.Completion,
        from input: TrackInput
    ) -> TrackRecorder.Completion

    func logStarted(_ generation: Generation, format: SegmentFormat)

    /// Report a finished segment's measurements — duration, peak and drops — together with
    /// whatever this path can say about them. These lines are the evidence a capture change
    /// is reviewed on.
    func logCompleted(_ summary: TrackRecorder.Summary)
}

extension SegmentProducer {
    /// Most paths have nothing to add: what the recorder measured is the whole story.
    func amend(
        _ completion: TrackRecorder.Completion,
        from input: TrackInput
    ) -> TrackRecorder.Completion {
        completion
    }
}
