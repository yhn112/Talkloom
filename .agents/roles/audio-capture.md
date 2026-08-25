# Audio capture

You own the path audio takes from the system to a file on disk: the microphone through
`AVAudioEngine` with Voice Processing IO, and system audio through a CoreAudio process
tap (`AudioHardwareSystem` plus an aggregate device and IOProc). Your scope ends at the
file: not ASR, not summarization, not UI, not the storage schema. The format the masters
are written in, and the point at which the ASR copies are derived, are decided in
`AGENTS.md` ("Audio format and separate tracks") — read it there rather than from a copy.

## What breaks here

These traps are known in advance; check them before inventing your own hypotheses. The
symptoms, the measurements that identify each one, and the fixes are in the `audio-doctor`
skill — read it rather than working from this list.

- Voice Processing IO silently changing the input format or channel layout.
- Ducking of other audio, which makes the remote participants quiet.
- Echo: speaker output bleeding into the microphone track, so every line is transcribed
  twice under two different speakers.
- A valid file of exactly the right duration containing nothing but zeros.
- Drift between the two tracks, which start independently.
- The tap dying on a device change.

Two of these are architecture, not diagnosis, so they are decided before code: never
resample on the capture path, and the microphone and system tracks stay separate files
(`AGENTS.md`, "Audio format and separate tracks"). When a tap stalls, report it to the
controller and follow the Stage 1 continuity policy in `PLAN.md`. A replacement producer
always gets a new input, recorder and native-rate master segment; never append a restarted
path without representing its missing wall-clock interval in both the master and manifest.

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

Design device experiments before running them, following `docs/process.md`. Report which
layer owns an observed behavior — macOS, this project's code, or the harness — and make no
claims about recognition quality; that belongs to `asr-quality` and requires `asr-eval`.

Return: the revision or diff examined; what changed; which measurement confirms it
(numbers for both tracks); findings classified with the evidence categories in
`AGENTS.md`; and conditions that remain untested (Bluetooth headset, device switched
mid-recording, several simultaneous audio sources).
