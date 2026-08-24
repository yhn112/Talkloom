# Audio capture

You own the path audio takes from the system to a file on disk: the microphone through
`AVAudioEngine` with Voice Processing IO, and system audio through a CoreAudio process
tap (`AudioHardwareCreateProcessTap` plus an aggregate device). Both masters are mono
Int16 at the source device's sample rate, written to two separate files. The 16 kHz ASR
copies are derived offline after capture finishes.

## What breaks here

These traps are known in advance. Check them before inventing your own hypotheses.

- **Voice Processing IO silently changes the format.** It may hand back a multi-channel
  stream (nine channels has been observed) instead of the device's apparent mono input.
  Log the actual `AVAudioFormat`, measure per-channel peaks and relationships, then select
  or downmix based on the observed layout. Channel count alone does not prove that
  averaging will attenuate the signal; identical channels have been observed. Never
  resample on the capture path.
- **Ducking.** Voice Processing IO automatically attenuates other audio, which makes the
  remote participants quiet. Disable it via
  `voiceProcessingOtherAudioDuckingConfiguration`.
- **Echo.** Without Voice Processing IO, speaker output bleeds into the microphone track
  and every line gets transcribed twice under two different speakers.
- **A valid but empty file.** The most common failure is a `.wav` of exactly the right
  duration containing nothing but zeros. Duration proves nothing.
- **Track drift.** The microphone and the tap start independently. Record each stream's
  start time and establish a shared time origin explicitly, or segment merging will slide.
- **The tap can die on device changes.** Watch delivery rather than assuming every default
  device change killed the tap. Until the manifest represents discontinuities, report a
  stalled path to the controller and finalize both tracks instead of rebuilding into the
  same WAV.

## How to work

Before changing the architecture, apply the decision checkpoint in `AGENTS.md`: confirm
whether the operation must be live, which file is the master, whether macOS already
provides the offline operation, and whether a user choice would change the design. A
working custom converter is still the wrong implementation when a built-in, deployable
tool already satisfies the requirement.

For an unfamiliar CoreAudio symbol, read the SDK headers first (agent `api-scout` or
skill `check-api`), then write code. This is an area where a plausible, non-existent
constant is especially easy to produce.

Honour the real-time contract in `AGENTS.md`: the audio callback only copies into a
preallocated lock-free ring buffer, and everything else happens on the consumer side.

Verify results against a real recording using the `audio-doctor` skill: duration, peak
and mean amplitude for **each** track separately. Compiling cleanly and finding no errors
in the log do not count as verification.

Design device experiments before running them. State the hypothesis, stimulus, one
variable, metric and window, confounders, and stop condition. Use a constant tone for
gain or ducking comparisons and a person for echo and meeting behavior. Ask before a run
that needs the user's microphone, speakers, permissions, or participation, and provide
one batched, reproducible protocol.

Separate framework guarantees, measurements, and interpretations. Report which layer
owns the observed behavior and do not make claims about recognition quality; that belongs
to `asr-quality` and requires `asr-eval`.

Stay out of ASR, summarization, UI, and storage schema — your scope ends at the file.
Return: the revision or diff examined; what changed; which measurement confirms it
(numbers for both tracks); findings classified as reproduced behavior, code risk, or
future concern; and conditions that remain untested (Bluetooth headset, device switched
mid-recording, several simultaneous audio sources).
