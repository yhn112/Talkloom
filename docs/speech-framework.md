# Apple's Speech framework as an ASR and VAD candidate

What macOS 26's `Speech` module offers a meeting transcriber, and which of it this project
can use. Every claim below is either a signature read out of the framework's Swift interface
or a value printed by a probe on this machine; nothing here is inferred from documentation.

Read before choosing a VAD, and before building the local ASR engine `PLAN.md` stage 2 names.

## Where the signatures come from

`Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface`
inside the macOS SDK that `xcrun --show-sdk-path` selects. Line numbers below are that file
in the SDK the probe ran against; `scripts/doctor.sh` prints which SDK this machine has.

The probe ran on macOS 26.6.2 (25G83) with Xcode 26.6, against the macOS 26.5 SDK.

## Confirmed facts

**The whole module family starts at macOS 26.0.** `SpeechAnalyzer` (line 207),
`SpeechDetector` (254), `SpeechTranscriber` (335) and `DictationTranscriber` (49) all carry
`@available(macOS 26.0, ...)`. Using any of them means moving the deployment floor, which is
at macOS 15.0 for the reason `AGENTS.md` states.

**`SpeechDetector` is not a standalone voice-activity detector.** Running an analyzer whose
only module is the detector traps inside the framework:

```
Speech/SpeechDetector.swift:223: Fatal error: Cannot create SpeechDetector-only worker; use with a transcriber module
```

Its `availableCompatibleAudioFormats` reports a single `0 ch, 0 Hz` format on its own, which
is the same fact showing up before the trap. So macOS 26 does **not** supply a VAD that can
be put in front of a cloud engine or in front of whisper: the detector is an endpointer for
Apple's own transcribers, not a component. A VAD for any other engine still has to come from
somewhere else.

**`SpeechTranscriber` has no Russian.** `supportedLocales` (402) returned 30 locales — de, en,
es, fr, it, ja, ko, pt, yue, zh — and no `ru`. For a project whose meetings are Russian and
English this rules it out as the local engine.

**`DictationTranscriber` does have Russian.** `supportedLocales` (131) returned 54 locales
including `ru_RU` and `uk_UA`, and `installedLocales` on this machine returned `en_GB`,
`en_US`, `ru_RU`. It is a different model from `SpeechTranscriber` — the dictation one — and
it is the only first-party path to Russian recognition.

**The analyzer wants exactly the format this project already derives.**
`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` (233) for a detector plus a
Russian `DictationTranscriber` returned `1 ch, 16000 Hz, Int16` — the canonical ASR format in
`AGENTS.md`, which `SessionAudio` produces from the masters.

**There is an offline batch entry point.** `analyzeSequence(from audioFile:)` (331) consumes a
finished `AVAudioFile`, which is the shape this project needs: nothing is live, and
transcription happens after the meeting. `SpeechAnalyzer(modules:)` (208) is the initializer
that pairs with it; the `inputSequence:` initializer (209) is for a live stream and leaves
`analyzeSequence` waiting forever if the sequence it was given has already finished.

**An asset install stands between the API and a first result.**
`AssetInventory.status(forModules:)` (35) returned `installed` for the detector alone but
`supported` for a Russian `DictationTranscriber`, with or without the detector — so
`AssetInventory.downloadAndInstall` (498) has to run before analysis, even though
`installedLocales` lists `ru_RU`. That download was not performed.

## Not established

- **Recognition quality on real meetings.** The synthetic fixtures have since been measured
  and the numbers are in [`Tests/reports/baseline.md`](../Tests/reports/baseline.md), but
  synthesis overstates quality for every engine equally. Nothing here has been compared with a
  `large-v3`-class model, and nothing has been run on real speech in a real room.
- **Whether a bundled app needs a TCC grant.** Analysis has since run to completion from a
  command-line tool with `SFSpeechRecognizer.authorizationStatus()` at `notDetermined` and no
  prompt shown, so the engine does not demand a grant to run. Whether a signed, bundled app
  behaves the same is not established, and TCC decisions are made per bundle.
- **What the asset download costs** in bytes, time, or network access at analysis time.

## What follows for this project

Moving the deployment floor to macOS 26 buys a first-party Russian recogniser that brings its
own endpointing — not a VAD. A VAD in front of the OpenRouter engine is needed either way, so
that choice is independent and does not have to wait for this one.

What the measurement then added: the engine returns **word-level** time ranges through the
`audioTimeRange` attribute on its result text, and produced no text at all on silence. So for
the Apple path the separate VAD stops being necessary — the word gaps are the pauses — while
its single-locale requirement makes a sentence that switches language mid-way the case it
handles worst. Both are in the baseline.
