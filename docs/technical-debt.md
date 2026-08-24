# Technical debt and simplification opportunities

This document records current design and implementation debt that should be resolved before
offline transcription is built on top of capture. It is not a second product roadmap:
`PLAN.md` owns product stages, while this file owns concrete cleanup and correctness work.

## Priorities

### P0 — make capture health explicit

- Do not use successful tap creation as the safety condition for microphone AEC. The
  permission UI now remains unverified until capture observes a non-silent signal, but AEC
  still has to be chosen before that evidence exists. A silent tap can therefore remove the
  remote side from the only usable track. The signed controller device test reproduced
  this exact ambiguity: two runs produced system peaks of 0.3291 and 0.0000 respectively,
  while both files had the expected duration and reported no dropped frames. The public SDK
  has no AudioCapture authorization or tap-health query; resolving this requires a
  data-preserving capture policy, not another permission check.
- Represent one active session and its two track states in one place. The current state is
  spread across `RecordingController.State`, `warning`, permission state, last summaries,
  and the capture actors' optional recorders, and those sources can disagree.
- Surface disk-write failure while recording, not only when the user stops. After
  `PCMWriting.append` throws, `TrackRecorder` records the error and permanently stops
  draining, but neither capture actor nor the controller is notified until `finish()`.
  The producer continues, the UI still says that recording is active, and the remainder of
  the meeting is lost. The existing failing-writer test confirms this contract at the
  recorder seam; the exit criterion is an immediate session failure that stops and
  finalizes both tracks.

### P0 — persist a truthful timeline

- Checkpoint first-sample timestamps while recording. A session skeleton is now written as
  soon as its directory is reserved, so a crash is distinguishable from successful
  completion, but repairing a WAV header still cannot reconstruct track alignment if all
  timing existed only in memory.
- Preserve the position of every dropped block. The ring buffer currently counts discarded
  samples, then the recorder writes the next accepted block directly after the previous
  one. That removes time from one track, shifts everything after the drop relative to the
  other track, and still produces a `completed` manifest containing only an aggregate drop
  count. Existing ring-buffer and oversized-block tests reproduce the drop path. Until the
  manifest can represent timed spans, any drop must fail and stop the whole session rather
  than leave a compressed timeline behind.
- Treat failure to replace the in-progress manifest as a session failure visible to the
  user. `RecordingController.writeManifest` currently logs the error and returns, after
  which the controller enters `idle`; the WAV files can therefore be finalized while the
  only manifest still says `recording` and contains no track timestamps. The exit criterion
  is that manifest finalization participates in the controller result and cannot be
  reported as a successful stop.
- Recover interrupted sessions by manifest status, not only by manifest absence. A
  recording interrupted by a crash or a kill leaves WAV headers claiming zero bytes, so
  the tracks read as empty although the samples are on disk. Recovering only sessions
  that have no `session.json` misses exactly that shape: new sessions write the manifest
  with `status == recording` before capture begins, so the file is always there. On
  launch, inspect `recording` manifests first, retaining missing or unreadable manifests
  as a legacy case; repair WAV sizes from the file length without claiming track
  alignment that was never checkpointed.

## Simplification opportunities

### Remove unused surface area

- Make capture `start()` methods return only data a caller actually consumes. Their current
  format/sample-rate return values are ignored by production code and duplicate the final
  summary.

### Give CoreAudio resources one owner

Tap, aggregate-device and IOProc cleanup is repeated in normal stop, `deinit`, and initial
rollback. Some error paths already omit part of the cleanup, and all teardown status values
are discarded.

One concrete leak occurs after `createTap()` succeeds but before the recorder is installed:
if `TrackRecorder` cannot create its WAV writer, the local tap handle is neither destroyed
nor stored in `self.tap`, so `stop()` and `deinit` cannot reach it. Teardown calls also forget
the resource IDs even when an `AudioDeviceDestroyIOProcID` or aggregate/tap destroy call
fails, leaving no retry or useful diagnosis.

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
- Capture actors rely on `RecordingController` to serialize lifecycle calls. Both start a
  producer, then suspend while starting the recorder drain, and only afterwards publish the
  recorder as active. A direct `stop()` during that suspension sees no recorder and returns,
  while a second direct `start()` also passes the idle guard. Either encode
  `idle`/`starting`/`running`/`stopping` inside each actor or make controller-only ownership a
  contract that the type boundary enforces.
- A mic-only fallback with AEC disabled assumes remote speech is audible through speakers.
  With headphones, the remote side is absent from the microphone track. The track is now
  labelled `mixed` in `session.json` instead of passing for `me`, so the merge step can no
  longer attribute it to the user; how such a session should be transcribed — and whether
  the user should be warned before recording without the tap at all — is still open.
- Sample rates are rounded from `Double` to an integer WAV header while the unrounded value
  remains in the summary. Either validate integral rates or use one canonical integer rate.

## Diagnostic-tooling reproducibility

- `track_compare.py` rejects a session when its two master tracks have different sample
  rates, even though recording each device at its own native rate is a project invariant.
  Compare offline-derived tracks at one common rate, or resample inside the diagnostic while
  preserving each track's manifest offset. Cover the result with synthetic tracks whose
  rates differ and whose known alignment must survive conversion.
- The Python tools import `numpy`, `soundfile`, and `jiwer`, but no checked-in dependency
  manifest or lock file can recreate the repository's `.venv`. Add a `pyproject.toml` and
  lock file, then include a hardware-free smoke check for the three scripts in the normal
  gate. The virtual environment remains a derived local artifact.

## Test-structure cleanup

Several opt-in XCTest cases are measurement experiments rather than regression tests:

- startup timing tests mostly print timings without acceptance assertions;
- the voice-processing layout test prints per-channel measurements but proves only that
  channel zero is non-silent, and its real-time tap takes an `NSLock`, which can perturb the
  callback behavior it is supposed to measure;
- the ducking test exhaustively plays all hardware-dependent configurations;
- `testVoiceProcessingSuppressesTheSpeakers` compares peak amplitude with and without
  cancellation, and peak across a four-second recording is not a measure of cancellation.
  The canceller converges over the first seconds of a session, so the peak reports where
  the loud syllables happened to fall: the same configuration measured 0.0057, 0.0064,
  0.0078, 0.0835 and 0.6105 across five runs, and a single-engine variant of the same test
  produced 0.0076, 0.0588, 0.2783 and 1.0000. The test passes today by luck. Measure a
  settled RMS over a window that starts after convergence, the way the ducking table in
  `system-audio-capture.md` already does.

Move exploratory measurements into a manual diagnostics or benchmark target. Keep the
device scheme focused on short end-to-end invariants: both paths start, contain meaningful
signal, share a timeline, finalize correctly, release devices, and clean up after failure.

The device tests also repeat temporary-directory and `say`/`afplay` process management.
Provide one test harness whose cleanup is `defer`-based and resilient to thrown errors. Test
host crashes and forced interruption can still leave private audio behind, so document and
provide an explicit cleanup command for those artifacts.

## Documentation ownership

**Status: mostly resolved.** Which file owns what is now a rule in `AGENTS.md` ("One
fact, one place"), and its mechanical half is enforced by `scripts/check_docs.py` inside
`scripts/check.sh`: no version literals in `.agents/`, no dangling paths, no roster drift
between the two clients, and the bundle identifier checked against `project.yml`.

Reproduced evidence for the original item: `a1e9e68` raised the deployment floor to
macOS 15 and updated `project.yml`, `PLAN.md` and `docs/system-audio-capture.md`, leaving
the old floor in `.agents/roles/api-scout.md` and `.agents/skills/check-api/SKILL.md`.
Both are corrected and the check now fails on a reintroduced version literal.

A second instance, found and fixed the same way: `PLAN.md` carried the WAV-header
recovery as a Stage 1 work item while the P0 above already owned it, and the two had
diverged — the plan prescribed recovering sessions without a `session.json`, which the
current code never produces. `PLAN.md` now states which stage is current and leaves work
items to this file.

Remaining, not blocking: the claim that capture writes 16 kHz files or uses a live
converter no longer appears anywhere, but the resampling argument is still stated twice
inside `AGENTS.md` itself (the decision, and again as an example under "Ask the user to
make the sound"). Exit criterion: one statement of the measurement in `AGENTS.md`, cited
rather than repeated elsewhere. The check cannot see this — prose duplication inside one
file is a human review job.

## Deferred recovery

Capture currently stops and finalizes the whole session when either path dies. Seamless
recovery is intentionally deferred: before appending a restarted path, define either
silence padding derived from host time or a timeline made of spans with their own host-time
anchors, then cover device switches with real-device tests.

## Resolved during the Stage 1 audit

- Recording startup is transactional, and explicit `starting`/`stopping` states reject
  overlapping UI operations.
- Capture actors report runtime failures to the controller; neither actor silently rebuilds
  or restarts into an existing WAV.
- Session directories are atomically reserved, so starts in the same second cannot truncate
  each other's tracks.
- The unused ScreenCaptureKit linkage and dead recorder/manifest properties were removed.
- WAV append and finalization failures propagate through capture stop to the controller.
  Partial summaries describe only successfully written frames, and both track-level and
  session-level failures are preserved in `session.json`.
- Unexpected system-audio buffer layouts fail the track instead of accumulating as an
  unreported diagnostic count.
- Session creation writes an in-progress manifest before capture starts; normal stop
  replaces it atomically with `completed` or `failed` when the final write succeeds, and
  legacy manifests remain readable. Failure of that final write is still active debt above.
- Every track declares who is on it — `local`, `remote` or `mixed` — and a session that
  fell back to the microphone alone carries the reason in `session.json` instead of only in
  the menu bar, which was gone by the next recording.

## Intentionally retained complexity

The following pieces are justified by current requirements and should not be simplified
away without new evidence:

- separate microphone and system tracks;
- a preallocated SPSC ring buffer between a real-time callback and disk I/O;
- hardware host time for cross-track alignment;
- native-rate masters and offline resampling;
- explicit peak/drop measurements that make silent or discontinuous capture observable;
- deterministic WAV writing, provided errors and crash recovery are handled explicitly.
