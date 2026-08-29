# Apple's Speech framework: evaluated, not used

**Decision: Talkloom does not use `Speech` — not for recognition, not for endpointing, not
as an evaluation comparator.** This file exists so the exploration is not repeated. It records
what the framework offers, what it measured, and why that was not enough.

## What it offers

Read out of
`Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface`
inside the macOS SDK that `xcrun --show-sdk-path` selects; line numbers are that file in the
SDK the probe ran against. `scripts/doctor.sh` prints which SDK this machine has.

- **The whole module family starts at macOS 26.0.** `SpeechAnalyzer` (207), `SpeechDetector`
  (254), `SpeechTranscriber` (335) and `DictationTranscriber` (49). Using any of it would have
  meant moving the deployment floor, which is at macOS 15.0 for the reason `AGENTS.md` states.
- **`SpeechDetector` is not a standalone voice-activity detector.** An analyzer holding it as
  its only module traps inside the framework with *"Cannot create SpeechDetector-only worker;
  use with a transcriber module"*, and on its own it advertises a `0 ch, 0 Hz` format. macOS
  supplies no VAD that can be placed in front of another engine.
- **`SpeechTranscriber` has no Russian**: 30 locales, none of them `ru`.
- **`DictationTranscriber` does**: 54 locales including `ru_RU`, with an asset install required
  once per locale before anything runs.
- `analyzeSequence(from audioFile:)` (331) consumes a finished file, which is the right shape
  for this project. `SpeechAnalyzer(modules:)` (208) is the initializer that pairs with it; the
  `inputSequence:` one (209) is for a live stream and leaves `analyzeSequence` waiting forever.
- `bestAvailableAudioFormat(compatibleWith:)` (233) asks for `1 ch, 16000 Hz, Int16` — exactly
  the format `SessionAudio` derives.
- Results carry **word-level** `audioTimeRange` and `transcriptionConfidence` attributes, and
  `AnalysisContext.contextualStrings` (469) does measurably change recognition.

## Why it is not used

Measured on the whole `podlodka_speech` test split, real spontaneous Russian technical speech;
the numbers are in [`Tests/reports/baseline.md`](../Tests/reports/baseline.md).

- **It loses the vocabulary the product exists for.** One of eleven English technical terms
  recovered, against nine for the cloud engine. `observability` came back as two different
  wrong words within one clip.
- **It never produced a clean clip.** 80.5% of words correct, 0 of 17 clips without an error,
  worst clip 52.5%.
- **It emits no punctuation or sentence boundaries at all**, which a summary stage would have
  to reconstruct.
- **It drops speech silently.** A whole exchange vanished from one clip. For a meeting record a
  silent omission is worse than a mangled word, because nothing marks it.
- Its confidence does not identify any of this: the most confident word in one utterance was
  wrong, and a correct word scored a third of it. So it cannot even be used as a cheap first
  pass that escalates its own weak spots.
- Contextual strings, the obvious remedy for terms, proved brittle: a fix that worked with one
  term supplied reverted when a second was added, and Latin-script terms inside Russian audio
  were never reached.

Any one of these would have been worth working around. Together they describe an engine that is
wrong about precisely the material this project records, and quiet about being wrong.

## What stands regardless

The absence of a system VAD is a fact about macOS, not about this decision: a voice-activity
detector for the offline chunking stage still has to come from somewhere else. `PLAN.md` names
Silero, and [`asr-evaluation.md`](asr-evaluation.md) records what adopting it would require.
