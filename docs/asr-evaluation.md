# ASR evaluation boundary

The first live cloud experiment sends only short, generated 16 kHz mono Int16 WAV fixtures
through the already-tested OpenRouter client. It deliberately runs without VAD: this isolates
credential, routing, audio encoding, structured response and timestamp behavior before a
second variable changes the audio boundaries. It is transport evidence, not a production
pipeline and not evidence about real meeting quality.

`scripts/asr-eval.sh` owns the measurement — fixture selection, timing, memory, hypothesis
extraction and metrics — for every engine, so that two candidates cannot be measured two
different ways and then compared. Engine-specific setup lives in a wrapper above it:
`scripts/openrouter-asr-eval.sh` enforces the local credential boundary described in
`AGENTS.md` without reading the secret, and only `OpenRouterASREval` reads the fixed ignored
file. `AppleSpeechASREval` has no credential and instead needs its on-device model installed
once per locale, which its `--install-assets` flag does.
The shared runner owns the ignored report layout;
[`Tests/fixtures/README.md`](../Tests/fixtures/README.md) owns the local setup and
fixture-generation entry point. Transcriber.app reads neither the evaluation key file nor the
environment and still requires a Keychain credential before it can construct a cloud request.

## VAD candidate decision

Do not adopt `paean-ai/silero-vad-swift` tag `1.0.0` at commit
[`60bbe344f72845a4dbd0543ed02917147016709a`](https://github.com/paean-ai/silero-vad-swift/commit/60bbe344f72845a4dbd0543ed02917147016709a)
unchanged. Its wrapper treats the CoreML model's 576-sample input as 576 new samples and
carries only the recurrent state. The official Silero v6 implementation advances by 512 new
samples at 16 kHz and prepends 64 samples of previous-audio context before inference; see the
official [`audio_forward`](https://github.com/snakers4/silero-vad/blob/fba061dc5559f696e62171e9a0741782b0fdc23c/src/silero_vad/utils_vad.py#L56-L106).

The package's stream wrapper also stops at a consecutive-silence counter. Stage 2 needs an
offline segmenter that owns onset/exit hysteresis, minimum speech and silence, speech padding,
maximum chunk duration, final-frame padding and clipped timeline intervals. Its behavior must
match the official model on a golden probability trace before any threshold is tuned.

Adoption therefore requires one controlled change after the no-VAD baseline:

- correct 512-new-sample plus 64-context framing and final-tail padding;
- actor ownership of the stateful, non-thread-safe CoreML model;
- table tests for segmentation and timeline mapping;
- an end-to-end comparison on the project fixtures, including silence hallucinations, WER,
  CER, insertions, timestamp boundary error, real-time factor, peak memory and cost.

The package and its bundled model are MIT-licensed, but if any portion is later adopted its
`THIRD_PARTY_NOTICES` content must accompany the distributed app.

The current measured no-VAD comparator is recorded in
[`Tests/reports/baseline.md`](../Tests/reports/baseline.md). It is the baseline for the VAD
experiment, not a claim about real-meeting quality.

## A reference is only as good as its provenance

A fixture's reference text has to be traceable to people who wrote it down, and that has to be
established before any number is quoted from it. A corpus whose transcripts were produced by an
ASR model can still be used to compare two engines against each other, because both are wrong
against the same text; it cannot be used to say what either engine's word error rate is.

Published documentation is one way to establish it and direct review is another. Where a corpus
documents nothing, someone reading its transcripts against its audio and vouching for them is
evidence — recorded as such, naming who did it, so a later reader knows the basis is a person
rather than a paper. `Tests/reports/baseline.md` records which corpora were checked, what was
found, and which known defects survive in the ones being used.

## The tiered engine, and why it is closed

A tiered arrangement was worth evaluating: transcribe locally, spend a cloud request only where
the local result is weak. Two measured properties would have made it buildable — the on-device
engine reported word-level time ranges, so a weak stretch could be named in seconds and cut out
of the derived track exactly, and because the escalated chunk's position comes from our own
boundaries the cloud engine would have been asked only for text, the one thing it does
reliably.

It is closed because the local tier is. Apple's engine was the only on-device candidate that
needed no model file, and it is not used at all — see
[`speech-framework.md`](speech-framework.md). What killed the tiering separately is that its
confidence could not find its own errors: the most confident word in one utterance was wrong
and a correct word scored a third of it. A first pass that cannot mark its weak spots cannot
route them anywhere.

Nothing here rules out tiering over a different local engine. It would need the same two
things: timing precise enough to cut on, and a signal that predicts error well enough to route
on. The second is the hard one, and the measurement to run first.

## Product-pipeline boundary

The fixture runner is intentionally below the product orchestration layer. It accepts an
already-derived WAV and calls one provider client; it does not prove that a completed app
session can be converted, segmented, transcribed, aligned or persisted. The real-recording
probe recorded in the baseline had to assemble those stages manually and exposed the
provider-response failure tracked as D22 in
[`docs/technical-debt.md`](technical-debt.md).

Future quality runs must enter through the same completed-session orchestration used by the
app. Fixture-level requests remain useful for transport and model comparisons, but they are
not an end-to-end acceptance gate; D23 tracks replacing that false boundary.
