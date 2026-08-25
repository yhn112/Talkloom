# Technical debt and simplification opportunities

Concrete design and correctness work to resolve before offline transcription is built on
top of capture. `PLAN.md` owns product stages; this file owns the work items. "What to do
next" is the current stage in `PLAN.md` plus the P0 items here.

Each item has a stable identifier so a commit can name what it resolves, and one metadata
line: `status · severity · evidence`. Evidence uses the categories in `AGENTS.md` —
confirmed fact, reproduced behavior, code risk, future concern. P0 is reserved for a
reproduced failure, a violated invariant, or a path that loses user data.

Resolved items are deleted rather than archived. Git holds that history better, and a
list of finished work buries the open items beside it. Identifiers are never reused.

## P0 — capture health

### D2 — one session's state has five representations
`open · P0 · code risk` — State is spread across `RecordingController.State`, `warning`,
permission state, the last summaries, and the capture actors' optional recorders, and
those sources can disagree.
**Exit:** one active session and its two track states represented in one place.

## P0 — a truthful timeline

### D23 — a capture-path restart must preserve wall-clock time
`open · P0 · confirmed fact` — Capture currently stops and finalizes the whole session when
either path dies, which violates the Stage 1 continuity requirement in `PLAN.md`. A simple
append after restart is not acceptable because it compresses the timeline; the gap duration
must be derived from the old and new spans' host-time anchors and recorded in the manifest.
**Exit:** the manifest represents anchored spans and gaps; restart inserts the corresponding
native-rate silent frames without stopping the session; retry exhaustion is visible to the
user; and real-device tests switch the output device and verify both track durations,
offsets, gap length, and post-restart signal.

## Simplification

### D5 — capture `start()` returns values nobody consumes
`open · P2 · code risk` — The format and sample-rate return values are ignored by
production code and duplicate the final summary. **Exit:** return only what a caller uses.

### D6 — CoreAudio resources have no single owner
`open · P1 · code risk` — Tap, aggregate-device and IOProc teardown still has no owner that
retains a resource after its destroy call fails. Acquisition rollback and normal teardown
now share the Swift handle wrappers and log failures, but the caller discards those wrappers
afterwards, leaving nothing to retry.
**Exit:** one resource owner that acquires IDs step by step, destroys them in reverse
order, logs teardown failures, and stays responsible until cleanup succeeds — replacing the
duplicated branches rather than wrapping them.

### D7 — `TrackInput` carries five concerns and a second unchecked escape
`open · P1 · code risk` — It combines two source APIs, interleaved and deinterleaved
layouts, generic multichannel averaging, timestamp diagnostics and the ring-buffer handoff,
and it is `@unchecked Sendable`, which `AGENTS.md` allows only for the ring buffer.
**Exit:** the tap path is a validated Float32 copy path, the microphone has an explicit
measured channel policy, and no generic mixer runs in a real-time callback.

### D8 — track health is interpreted in four places
`open · P1 · code risk` — Silence, clipping and near-clipping decisions are made in the
recorder, the capture actors, controller logs and the UI. Separately, a single peak
threshold cannot establish that a long recording contains speech.
**Exit:** track health represented once, on a duration-aware measure such as windowed
activity, and permission state no longer inferred from it.

## Assumptions not yet encoded

Premises the code relies on that no test or header confirms. Each becomes a defect the
first time a machine disagrees.

### D9 — the tap's format is assumed, not validated
`open · P1 · code risk` — Cast to Float32 without checking `mFormatID`, format flags or
bytes per frame; measured as packed Float32 on one machine and treated as a platform
guarantee. **Exit:** validate, or fail the track explicitly.

### D10 — exactly one `AudioBuffer` is assumed
`open · P1 · code risk` — Every other layout is dropped, on an observation specific to the
tap-only aggregate tested so far. **Exit:** a validated layout contract or an explicit
failure.

### D11 — microphone channels are averaged equally
`open · P1 · code risk` — Device diagnostics prove only that channel zero carries signal,
not that every reported channel carries the same signal. **Exit:** a measured
channel-selection or downmix policy.

### D12 — `maximumFrameCount == 16_384` is a fixed limit
`open · P2 · code risk` — Not derived from the device's maximum slice size, and a larger
callback is discarded whole. **Exit:** derive it, or reject the device at start.

### D13 — the watchdog assumes continuous delivery
`open · P2 · code risk` — It assumes `tapAutoStart == false` yields frames continuously on
every supported macOS version and device, and that two seconds without accepted samples
means the tap is dead. **Exit:** confirmed against a header, or measured across device
changes.

### D14 — capture actors rely on the controller to serialize lifecycle calls
`open · P1 · code risk` — Both start a producer, suspend while starting the recorder drain,
and only then publish the recorder as active. A direct `stop()` during that suspension sees
no recorder and returns; a second direct `start()` also passes the idle guard.
**Exit:** `idle`/`starting`/`running`/`stopping` encoded inside each actor, or
controller-only ownership enforced by the type boundary.

### D15 — a mic-only fallback assumes the remote side is audible through speakers
`open · P1 · code risk` — With headphones it is not. The track is labelled `mixed` in
`session.json`, so the merge step cannot attribute it to the user, but how such a session
should be transcribed — and whether to warn before recording without the tap at all —
remains open. **Exit:** a product decision, then the behaviour it implies.

### D16 — sample rates are rounded in the header but not in the summary
`open · P2 · code risk` — The WAV header takes an integer while the unrounded `Double`
stays in the summary. **Exit:** validate integral rates, or use one canonical integer rate.

### D17 — recovery assumes a single running instance
`open · P2 · code risk` — `SessionRecovery` repairs every directory whose `session.json`
says `recording`, so a second copy of the app recording right now would have its live
session repaired underneath it. The app is a menu-bar singleton, which makes this an
assumption rather than a reproduced defect. **Exit:** recovery skips a session another
instance owns, or single-instance is enforced rather than assumed.

## Tooling and tests

### D18 — `track_compare.py` rejects native-rate masters
`open · P1 · code risk` — It refuses a session whose two masters have different sample
rates, although recording each device at its own native rate is a project invariant: the
diagnostic rejects exactly the recordings the project produces.
**Exit:** compare offline-derived tracks at one common rate, or resample inside the
diagnostic while preserving each track's manifest offset, covered by synthetic tracks whose
rates differ and whose known alignment must survive conversion.

### D20 — device diagnostics are experiments wearing the shape of tests
`open · P1 · reproduced` — Startup timing tests mostly print without asserting; the
voice-processing layout test proves only that channel zero is non-silent, and its real-time
tap takes an `NSLock`, which can perturb the callback behaviour it measures; the ducking
test exhaustively plays every hardware-dependent configuration. Worst,
`voiceProcessingSuppressesTheSpeakers` compares peak amplitude with and without
cancellation, and peak across four seconds does not measure cancellation — the canceller
converges over the first seconds, so peak reports where the loud syllables fell. The same
configuration measured 0.0057, 0.0064, 0.0078, 0.0835 and 0.6105 across five runs, and a
single-engine variant produced 0.0076, 0.0588, 0.2783 and 1.0000. **It passes by luck.**
The shared speech stimulus also suppresses `Process.run()` failure with `try?`, and callers
do not establish that playback happened. A controller run consequently recorded a zero-peak
system track while the user heard no stimulus; the immediately following system-only and
controller runs carried signal normally, so that run is evidence about the harness rather
than a tap failure.
**Exit:** exploratory measurements move to a manual diagnostics or benchmark target;
cancellation is measured as settled RMS over a window starting after convergence, as the
ducking table in `docs/system-audio-capture.md` already does; the device scheme keeps only
short end-to-end invariants — both paths start, carry signal, share a timeline, finalize,
release devices, clean up after failure.

### D21 — device tests repeat their own scaffolding
`open · P2 · code risk` — Temporary-directory and `say`/`afplay` process management is
duplicated across them, and a test-host crash or forced interruption can leave private
audio on disk. **Exit:** one harness whose cleanup is `defer`-based and survives thrown
errors, plus a documented cleanup command for what a crash leaves behind.

## Intentionally retained complexity

Justified by current requirements. Do not simplify these away without new evidence:

- separate microphone and system tracks;
- a preallocated SPSC ring buffer between a real-time callback and disk I/O;
- hardware host time for cross-track alignment;
- native-rate masters and offline resampling;
- explicit peak and drop measurements that make silent or discontinuous capture observable;
- deterministic WAV writing, provided errors and crash recovery are handled explicitly.
