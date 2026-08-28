---
name: asr-eval
description: Measure recognition quality in Russian and English — WER, CER, hallucinations on silence, coverage of the audio sent, speed, and memory. Use when changing the ASR model or engine, when tuning VAD or chunking, and when transcripts come out poor. Do not use to diagnose the recording itself — that is audio-doctor.
---

# Evaluating ASR quality

ASR changes are accepted on measurement, not on impression. "Sounds better" is not a
result: a change that improves English usually degrades Russian, and loosening filters
"for completeness" brings back the hallucinations `docs/asr-evaluation.md` records, which a
short sample will not reveal.

## Fixtures

Audio and reference-text pairs live in `tests/fixtures/` as `<name>.wav` next to
`<name>.txt`. The set must at minimum cover:

- Russian speech, English speech, and a mixed Russian-English utterance;
- a recording with long pauses and one of pure silence — these are what catch
  hallucinations;
- where possible, a real meeting excerpt with background noise and interruptions.

A fixture needs a reference transcript, and one no longer has to be written by hand:
`scripts/generate-asr-reference.sh` writes one beside a WAV using the cloud engine, with a
sidecar naming the model and the audio's checksum. `docs/asr-evaluation.md` states when that is
legitimate and the three things such a reference may not be used for — read it before scoring
anything against a generated reference.

Synthetic speech is available for a quick smoke test:

```bash
say -v Milena --file-format=WAVE --data-format=LEI16@16000 -o tests/fixtures/ru_short.wav \
  "Коллеги, давайте зафиксируем решение по архитектуре захвата звука."
say -v Samantha --file-format=WAVE --data-format=LEI16@16000 -o tests/fixtures/en_short.wav \
  "Let us agree on the audio capture architecture before the next sprint."
```

Synthesis is a smoke test only: it is clean, free of noise, interruptions, and real
articulation, and it overstates quality. Decide about models on real recordings; use
synthesis to catch gross breakage.

## Measuring

1. Run the fixtures through the current pipeline and write hypotheses to
   `tests/reports/<run>/`.
2. Compute metrics **per language** — averaging Russian and English together hides the
   very thing the measurement exists to expose:

   ```bash
   scripts/.venv/bin/python scripts/wer.py --ref tests/fixtures/ru_short.txt \
     --hyp tests/reports/<run>/ru_short.txt --align
   ```

   `--align` prints the alignment with errors highlighted, which shows the character of
   the errors rather than just their count. Normalization (case, punctuation, ё→е) is on
   by default; without it the metric measures punctuation rather than recognition.

3. Check silence and pauses separately. On the silence fixture the reference is empty, so
   don't look at WER — look at whether any text appeared at all: anything here is a
   hallucination. On speech fixtures the same problem shows up as a spike in insertions,
   which `wer.py` warns about on its own.

4. Record speed relative to real time and peak memory. Quality bought with a threefold
   slowdown is a different decision, not the same one.

5. For a remote engine, check **coverage before anything else**: where the returned segments
   stop, against the duration of the chunk that was sent. If it falls short, measure energy
   over the uncovered interval and say whether the audio ended or the response did — a WER
   quoted before that question is answered is not a result. `docs/asr-evaluation.md` owns why,
   and records the run where this came up. Record the wall-clock turnaround including upload,
   and the provider cost, on the same line.

## Rules

Compare against the recorded baseline in `tests/reports/baseline.md`, not against a
recollection of a previous result. When you move the baseline, update that file and state
how the run differed. A baseline entry names the engine and the exact model version, so that
a provider changing a model under the same name cannot be read as a regression here.

Change one parameter per run. Changing the model and the VAD settings together makes it
impossible to tell which one mattered.

If no fixture covers your hypothesis, add the fixture first.

Capture metrics are not a substitute for this evaluation, and an ASR regression does not
identify a capture cause without a separate `audio-doctor` measurement (`AGENTS.md`,
"Separate facts, measurements, and hypotheses").

## What to report

A before/after table per language with WER, CER, and insertion counts; the result of the
silence check; and the cost in speed and memory. For a remote engine, report coverage and
provider cost too, and name the model version the numbers came from. Always name what regressed — a change
with no regression anywhere on any language is a reason to re-check the measurement
rather than to celebrate.
