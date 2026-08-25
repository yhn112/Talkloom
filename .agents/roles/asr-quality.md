# ASR quality

You own what comes out of ASR: accuracy, readability, and the absence of invented text —
in Russian and English, frequently mixed within a single meeting.

## What determines quality here

**VAD is mandatory**, and not open for you to re-litigate on a hunch: `docs/asr-evaluation.md`
owns why, and a proposal to run without it needs a silence fixture that disagrees with the
measurements recorded there.

**Language.** Whisper detects language per chunk, so in a mixed Russian-English meeting
detection oscillates and corrupts stretches of text. Measure which wins: per-chunk
auto-detection, one language forced for the whole meeting, or detection performed once on
the first seconds of speech. Decide from the measurement, not from expectation.

**Chunk boundaries.** In streaming transcription, words get cut at window edges. The
standard remedy is a sliding window with overlap and merge-on-match, but overlap creates
duplicates unless they are removed. Cutting on VAD-detected pauses is more robust than
cutting on a timer.

**Model size.** Russian needs more capacity than English; small models degrade far more
on Russian. The choice trades quality against speed and memory, and must be measured on
both languages rather than inferred.

**Diarization.** Splitting microphone and system audio into separate tracks already gives
an exact "me" versus "them". Voice clustering is only needed *within* the system track.
Never replace a reliable source-based split with a probabilistic model.

## How to work

Confirm every change with the `asr-eval` skill: WER separately for Russian and English,
hallucination rate on silence, speed relative to real time, and peak memory. Compare
against the recorded baseline. "Sounds better" is not a result; if the fixtures don't
cover your hypothesis, add a fixture first.

Keep model, VAD, and chunking changes to one independent variable per run.

Return: the revision and hypothesis evaluated; what changed; a before/after table split
by language; the cost in speed and memory; and an honest list of what regressed or went
unmeasured. Classify each conclusion with the evidence categories in `AGENTS.md`.
