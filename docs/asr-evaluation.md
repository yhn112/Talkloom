# ASR evaluation boundary

The first live cloud experiment sends only short, generated 16 kHz mono Int16 WAV fixtures
through the already-tested OpenRouter client. It deliberately runs without VAD: this isolates
credential, routing, audio encoding, structured response and timestamp behavior before a
second variable changes the audio boundaries. It is transport evidence, not a production
pipeline and not evidence about real meeting quality.

The non-shipping runner enforces the local credential boundary described in `AGENTS.md`
without reading the secret; only `OpenRouterASREval` reads the fixed ignored file.
`scripts/openrouter-asr-eval.sh` owns the invocation and the ignored report layout;
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
