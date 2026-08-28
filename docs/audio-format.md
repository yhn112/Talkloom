# Audio format, derivation, and the two tracks' timeline

The invariants are in `AGENTS.md` ("Audio format and separate tracks"): native-rate masters,
never resample on the audio path, two files that are never mixed, one common time origin.
This file holds the measurements and decisions those invariants were derived from, so the
rules can stay one line each.

## Why resampling never happens on the audio path

A resampler is a polyphase FIR. It holds roughly thirty input frames in its delay line and
releases them only when the stream is declared finished. A drain loop can never declare that
— more audio is always coming — so it abandons the filter's contents on every pass, and any
pass that hands the converter more input than one call consumes loses the remainder outright.
Both losses report success.

Measured (`1488134`): a one-second 48 kHz tone through a 50 ms drain loop lost 6% of the
recording. The same conversion over a finished file is frame-exact — one-second tones at
48 kHz and 44.1 kHz both derive to exactly 16000 frames of 16 kHz mono Int16 (`8f547ac`),
which is the property the offline step exists to have and the live loop measurably did not.

Nothing in this project needs live audio: transcription happens after the meeting, so the
constraint costs nothing. `Packages/TranscriberCore/Sources/TranscriberCore/Audio/SessionAudio.swift`
is the one place the conversion is allowed to run, over a completed session.

Keeping the master also means a better model can be re-run later against the original audio
rather than against a downsampled copy.

## Why `afconvert` and not `ffmpeg`

`afconvert` ships with macOS, so the app acquires no Homebrew dependency it cannot satisfy on
someone else's machine. This applies to anything Transcriber.app itself runs. `ffmpeg` stays
available to the Python evaluation tooling in `.venv`, which only ever runs on this machine.

## Why the two tracks start at different times, and why the gap is kept

The process tap delivers its first sample almost immediately. The microphone does not: the
echo canceller takes about 0.75 s to come up, and about 2.7 s the first time in a process —
measured at 2.709 s on a real recording
(`Tests/TranscriberTests/Device/StartupLatencyTests.swift`).
The engine's `start()` call returns long before the unit delivers anything, so the number that
matters is time to the first sample, not time to return.

The gap is accepted rather than hidden, which is a product decision and not a limitation:
closing it would mean holding the microphone open before the user asks to record, and a
transcriber that lights the microphone indicator while idle is not a trade this project makes.
The consequence is explicit — the meeting's opening seconds exist only on the system side —
and it is representable because each track's first-sample timestamp is written to
`session.json`.

## Why the split is the diarization foundation

Microphone and system audio in separate files give an exact "me" versus "everyone else" with
no model and no error rate. Every probabilistic diarization step this project may add later
runs *inside* the system track. That is why folding the two into one file is a product
regression rather than an optimization, however much simpler the single-file pipeline looks.

The mixed-microphone fallback is the one case where the split degrades, and it is recorded as
such: see `docs/system-audio-capture.md` for the probe that gates echo cancellation, and D15
in `docs/technical-debt.md` for what remains undecided about transcribing such a session.
