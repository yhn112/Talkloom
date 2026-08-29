# Recorder upstream reuse assessment

[`tobi/recorder`](https://github.com/tobi/recorder) is an explicitly approved upstream
implementation for features that overlap Talkloom. This assessment covers commit
[`f1b5c7455074253605ae6d55b0ef89f34efa3011`](https://github.com/tobi/recorder/commit/f1b5c7455074253605ae6d55b0ef89f34efa3011),
reviewed on 2026-08-25. The repository is MIT-licensed; its copyright and permission notice
must accompany any substantial copied portion.

The purpose of this reference is to skip repeated discovery, not repeated verification.
Before building an overlapping feature, read the relevant upstream file and the row below.
Prefer adapting a compatible implementation or interaction pattern over designing another
project-specific subsystem. Still verify unfamiliar system APIs against the installed SDK,
and run the Talkloom check required for the layer being changed. Another application's
source is evidence about that application, not a platform guarantee or a measurement of this
one.

If upstream changes materially, record the newly reviewed commit here and update only the
affected rows. Do not re-audit unrelated components. If code rather than an idea is copied,
record the upstream file and commit in the change and add its MIT notice to a repository-level
third-party notice in the same change.

## Component map

| Upstream component | Reuse posture | Talkloom boundary |
|---|---|---|
| `CalendarAccess.swift` | Adapt when Stage 6 starts | The long-lived `EKEventStore`, focused event window, change observation and attendee hints are useful. Verify EventKit APIs then because this code has not been built or tested in Talkloom. |
| `NotificationManager.swift` | Adapt when meeting integration starts | The actionable meeting-end notification and foreground presentation pattern fit Stage 6. Notification permission and signing behavior still need a local app check. |
| `RecordingsLibrary.swift` and folder-name sanitizing | Reuse as design input | Collision avoidance and tolerant directory discovery are useful. Talkloom's manifest and later SQLite store remain the source of truth, so folder-name parsing must not become identity. |
| `Keychain.swift` | Adapt behind a provider-neutral credential store | It demonstrates the small Security-framework surface needed by Stage 2 or 3. The first credential is an OpenRouter API key. Preserve explicit errors and use Talkloom's stable signing identity; do not copy its delete-then-add error suppression. |
| `GeminiTranscriber.swift` | Reuse the state, result and prompt boundaries | Gemini through OpenRouter is the first cloud implementation. The upstream client calls Google's Files API directly, so its resumable upload and processing poll do not apply. OpenRouter accepts base64 `input_audio` through Chat Completions; keep that transport behind the provider-neutral `Transcriber` protocol. |
| `RecorderPanel.swift`, preferences and meeting list | Reuse interaction patterns in Stage 6 | The compact menu-bar controls, recording library and nearby-meeting affordances fit the product. Adapt them to Talkloom's state machine and English UI rather than importing its model wholesale. |
| `FloatRingBuffer.swift` | Compare, do not replace | It confirms the same SPSC shape already used here, but Talkloom's ring buffer, pointer lifetime rules, drop accounting and sanitizer gate are stricter and already tested. |
| `SystemAudioTap.swift` | Use as an adversarial reference only | Tap creation, aggregate teardown and the zero-buffer rebuild path are relevant comparisons. The callback constructs objects, takes locks and calls closures; its rebuild appends across a possible format change and neither records a gap nor re-verifies signal. Those choices violate Talkloom's real-time and timeline invariants. |
| `MicCapture.swift` | Do not copy into the capture path | It allocates/downmixes, locks and writes an `AVAudioFile` in the audio callback. Talkloom permits only a copy into its preallocated ring buffer there and requires Voice Processing IO when verified system capture makes echo cancellation safe. |
| `StereoMixer.swift` | Do not reuse | It resamples and combines the two sources into stereo AAC. Talkloom keeps separate native-rate Int16 WAV masters and derives 16 kHz mono files with `afconvert` after recording. |
| Silence auto-stop and pause behavior | Product input, not an implementation default | Upstream drops samples while paused and can stop after two-channel silence. Neither behavior is in the current stage; both need an explicit product decision and a timeline representation before implementation. |

## Stage-specific use

### Completed Stage 1 reference

The useful upstream lesson is that a process tap may keep delivering callbacks containing
silence and that rebuilding both the tap and aggregate is a plausible recovery action. It
does not replace Talkloom's completed recovery contract: a restart here keeps the
unaffected path running, makes the missing wall-clock interval explicit, inserts native-rate
silence, verifies the rebuilt system path with an active signal and preserves the degraded
fallback if verification fails. Use the upstream implementation as a comparison if capture
recovery is revisited, not as a simpler replacement for that contract.

Do not import the upstream watchdog threshold. Its silence decision depends on output-device
activity and a fixed amplitude/time rule that has not been reproduced on this app's hardware.
It is a comparison case for D13, not evidence that D13 is resolved.

### Stage 2

Gemini through OpenRouter is the approved first cloud implementation. An explicitly supplied
OpenRouter credential lives in Keychain; without it the app constructs no network request.
Finished speech chunks are sent as base64 `input_audio` to
[OpenRouter Chat Completions](https://openrouter.ai/docs/guides/overview/multimodal/audio),
using both denied data collection and a
[zero-data-retention route](https://openrouter.ai/docs/guides/features/zdr), and the returned
transcript stays local. The direct Google Files API upload and processing poll from upstream
are not part of this transport.

Recorder's local credential fallback is reused only by the non-shipping ASR evaluation
runner. Talkloom.app does not inherit that fallback; its eventual durable credential
remains Keychain-only. The evaluation boundary and current VAD decision are recorded in
[`docs/asr-evaluation.md`](asr-evaluation.md).

Keep the implementation behind the `Transcriber` protocol, retain the local/cloud source
distinction in the UI, and evaluate Russian and English quality with the ASR fixtures. The
exact Gemini model remains configurable and must be measured rather than inherited from an
upstream preview model. Check the current OpenRouter request shape and audio-capable model
metadata before changing either.

### Stages 3 and 6

The highest-value reuse is outside the audio callback: Keychain storage, a recordings library,
EventKit meeting context, actionable notifications, preferences and the menu-bar interaction
model. These components are small and isolated enough to adapt one at a time while keeping
Talkloom's manifest, privacy rules and later SQLite store authoritative.

## Known limits of the upstream evidence

- `swift build` passed for the reviewed commit on this machine, but the repository has no
  automated tests and no hardware run was performed. Its code can shorten implementation and
  research, but cannot be imported as verification.
- Its research notes contain competing recommendations about independent captures versus one
  aggregate containing the microphone. The shipped code uses independent captures, which also
  matches Talkloom's separate-path failure policy.
- Its raw format, post-processing, echo policy, signing and cloud provider are product choices
  for a different application. They are not simplifications available to Talkloom without
  changing requirements.
- Its Gemini transport talks directly to Google, while Talkloom uses OpenRouter. Only the
  provider state, prompt and local-result boundaries carry across that seam.
- OpenRouter and the chosen Gemini model expose the request shape and structured output, but
  not Russian/English meeting WER or timestamp accuracy. The client default is an integration
  baseline, not a quality verdict; the ASR fixtures still decide whether it is retained.
- Its mid-file sample-rate handling, real-time callbacks and silent-tap detector are useful
  review targets precisely because they expose failure modes our stricter invariants must rule
  out.
