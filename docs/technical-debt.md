# Technical debt and simplification opportunities

This document records known design and implementation debt that should be resolved before
offline transcription is built on top of capture. It is not a second product roadmap:
`PLAN.md` owns product stages, while this file owns concrete cleanup and correctness work
found during review of `feat/audio-capture` at `c2e34ab` plus its working-tree changes.

## Priorities

### P0 — make capture lifecycle explicit

Transactional startup, explicit `starting`/`stopping` states, and capture-to-controller
runtime failure events are implemented on the audio-capture branch. A startup failure rolls
back both paths, and a runtime failure finalizes both tracks before the UI reports failure.
The remaining lifecycle work is:

- Do not infer the system-audio TCC state from successful tap creation. A tap may start and
  still deliver silence; enabling microphone AEC in that state can remove the remote side
  from the only usable track.
- Represent one active session and its two track states in one place. The current state is
  spread across `RecordingController.State`, `warning`, permission state, last summaries,
  and the capture actors' optional recorders, and those sources can disagree.

### P0 — keep the recorded timeline truthful

- A first-sample timestamp is sufficient only for uninterrupted capture. A tap rebuild or
  microphone restart removes time from the WAV and shifts every later ASR timestamp.
- Until discontinuities are represented, prefer stopping the session visibly on a dead
  capture path over silently rebuilding into the same file.
- Before supporting recovery, define either silence padding derived from host time or a
  timeline made of spans with their own host-time anchors.
- Store an absent first-sample timestamp as unknown, not as offset zero. Zero currently
  means both "this was the earliest track" and "this track never started".
- Write a session skeleton early and checkpoint first-sample timestamps. Repairing a WAV
  header after a crash cannot reconstruct track alignment if all timing existed only in
  memory.

### P0 — surface failures instead of returning success-shaped data

- Persist the first WAV append or finalization error and return it through capture stop and
  the controller. A peak measured before a failed disk write is not evidence that the file
  is usable.
- Treat unexpected runtime buffer layouts as a track failure, not as an indefinitely
  growing count of silently discarded blocks.
- Preserve partial-track summaries and failure metadata when a capture actor stops early.
  Do not omit an existing partial file from `session.json` merely because a later `stop()`
  returns `nil`.

## Simplification opportunities

### Remove unused surface area

- Remove the unused `ScreenCaptureKit.framework` dependency until an actual fallback is
  planned and implemented.
- Remove unused `MicrophoneCapture.isRunning`, `SystemAudioCapture.isRunning`,
  `TrackRecorder.currentPeak`, and `RecordingManifest.Track.duration` members.
- Make capture `start()` methods return only data a caller actually consumes. Their current
  format/sample-rate return values are ignored by production code and duplicate the final
  summary.
- Remove comments that still describe an `AVAudioConverter` or resampling in the drain
  consumer. Capture now writes a native-rate mono Int16 master and resamples offline.

### Reduce self-healing until it can be correct

The MVP now applies the smaller policy:

1. detect a stopped path;
2. report it to the controller;
3. stop and finalize the whole session;
4. show the failure to the user.

Reintroduce seamless recovery only with discontinuity-aware metadata and device-switch
tests.

### Give CoreAudio resources one owner

Tap, aggregate-device and IOProc cleanup is repeated in normal stop, `deinit`, and initial
rollback. Some error paths already omit part of the cleanup, and all teardown status values
are discarded.

Use one small resource owner that acquires IDs step by step, destroys acquired resources in
reverse order, logs teardown failures, and remains responsible until cleanup succeeds or
the process exits. This should replace the duplicated teardown branches rather than wrap
them in another abstraction layer.

### Narrow `TrackInput`

`TrackInput` currently combines two source APIs, interleaved and deinterleaved layouts,
generic multichannel averaging, timestamp diagnostics and the ring-buffer handoff. It is
also a second `@unchecked Sendable` type despite the repository rule allowing that escape
hatch only for the ring buffer.

The system tap is requested as mono and should need a validated Float32 copy path. The
microphone needs an explicit, measured channel-selection or downmix policy. Narrowing those
contracts is preferable to a generic mixer running in every real-time callback.

### Consolidate track health

Silence, clipping and near-clipping decisions are interpreted in the recorder, capture
actors, controller logs and UI. Represent them once as track health/status data. A single
peak threshold is not sufficient to establish that a long recording contains speech; use
windowed activity or another duration-aware measure before treating a track as healthy or
using it to infer permission state.

## Assumptions that must be validated or encoded

- The process tap is cast to Float32 without validating `mFormatID`, format flags and bytes
  per frame. It was measured as packed Float32 on one machine, but the implementation
  treats that measurement as a platform guarantee.
- The system path requires exactly one `AudioBuffer` and drops every other layout. The
  one-buffer observation is specific to the tap-only aggregate tested so far.
- Microphone channels are averaged equally. Existing device diagnostics prove only that
  channel zero contains signal, not that every reported channel contains the same signal.
- `TrackInput.maximumFrameCount == 16_384` is a fixed limit not derived from the device's
  maximum slice size. A larger callback is discarded whole.
- The watchdog assumes that `tapAutoStart == false` produces frames continuously on every
  supported macOS version and device, and that two seconds without accepted samples means
  the tap is dead.
- A mic-only fallback with AEC disabled assumes remote speech is audible through speakers.
  With headphones, the remote side is absent from the microphone track and the recording
  must be marked partial/mixed rather than labelled `me`.
- Sample rates are rounded from `Double` to an integer WAV header while the unrounded value
  remains in the summary. Either validate integral rates or use one canonical integer rate.

## Test-structure cleanup

Several opt-in XCTest cases are measurement experiments rather than regression tests:

- startup timing tests mostly print timings without acceptance assertions;
- the voice-processing layout test prints per-channel measurements but proves only that
  channel zero is non-silent;
- the ducking test exhaustively plays all hardware-dependent configurations.

Move exploratory measurements into a manual diagnostics or benchmark target. Keep the
device scheme focused on short end-to-end invariants: both paths start, contain meaningful
signal, share a timeline, finalize correctly, release devices, and clean up after failure.

The device tests also repeat temporary-directory and `say`/`afplay` process management.
Provide one test harness whose cleanup is `defer`-based and resilient to thrown errors. Test
host crashes and forced interruption can still leave private audio behind, so document and
provide an explicit cleanup command for those artifacts.

## Documentation ownership

The native-rate/offline-resampling decision is repeated in `AGENTS.md`, `PLAN.md`, roles,
skills, source comments and tests, and the copies have already diverged. Keep ownership
narrow:

- `PLAN.md`: product stages and architectural outcomes;
- `AGENTS.md`: enforceable repository and implementation rules;
- `docs/`: measurements, API research and architecture decisions;
- roles and skills: how to perform or verify work, without restating the architecture;
- source comments: only the local invariant needed to understand that code.

In particular, remove remaining claims that capture writes 16 kHz files or uses a live
converter. The master is mono Int16 at the source sample rate; the 16 kHz ASR copy is an
offline derivative.

## Intentionally retained complexity

The following pieces are justified by current requirements and should not be simplified
away without new evidence:

- separate microphone and system tracks;
- a preallocated SPSC ring buffer between a real-time callback and disk I/O;
- hardware host time for cross-track alignment;
- native-rate masters and offline resampling;
- explicit peak/drop measurements that make silent or discontinuous capture observable;
- deterministic WAV writing, provided errors and crash recovery are handled explicitly.
