---
name: audio-doctor
description: Diagnose recorded tracks — empty recordings, a too-quiet remote party, echo, duplicated lines, drift between microphone and system audio, wrong format. Use after any change to the capture layer and whenever a transcript comes out empty or strange. Do not use to judge recognition quality — that is asr-eval.
---

# Diagnosing a recording

Audio capture fails quietly. The most common outcome is a valid `.wav` of the correct
duration full of zeros: the file exists, the duration is right, the log is clean, and
there is no signal. "It recorded" is therefore confirmed by numbers per track, not by the
appearance of a file.

## First measurement

```bash
.venv/bin/python scripts/audio_check.py Recordings/<meeting>/mic.wav Recordings/<meeting>/system.wav
```

The script prints format, peak and RMS in dBFS, the share of silence over 20 ms windows,
DC offset, and clipping; a non-zero exit status means at least one file looks broken.
Read the two tracks **separately** — usually one of them is fine, which halves the search
space immediately.

Reference values for live speech: peak between −20 and −3 dBFS, RMS around −30…−15 dBFS,
silence well under 90%.

## From symptom to cause

**Both tracks empty.** The app never received permission. Check whether the system
prompted at all, then grant again: `tccutil reset Microphone me.diskin.Transcriber`, the
same for `AudioCapture`, then restart the app. A silent denial with no dialog usually
means the bundle signature changed.

**Only the system track is empty.** The process tap was created but never attached to the
aggregate device, or it is attached to a process that isn't producing audio. Confirm audio
was actually playing during the recording. If the output device changed mid-recording
(headphones plugged in), the aggregate collapsed and the tap must be rebuilt on the
default-device-changed notification.

**Only the microphone track is empty.** Typically Voice Processing IO delivered a format
other than the expected one — a multi-channel stream instead of mono has been observed —
and the converter emitted silence without reporting an error. Log the actual
`AVAudioFormat` at the converter's input and compare it with what the code expects.

**The remote party is too quiet.** Voice Processing IO ducks other audio automatically.
Disable it via `voiceProcessingOtherAudioDuckingConfiguration`.

**Every line appears twice in the transcript under different speakers.** Speaker output is
bleeding into the microphone, so both tracks contain the same content. This needs echo
cancellation (Voice Processing IO) or headphones. Confirm by cross-correlating the tracks:
high correlation between supposedly independent sources is echo.

**Lines drift apart toward the end of the meeting.** The streams either started at
different moments or run at different effective rates. Record each stream's start time and
bring both tracks to a shared origin explicitly.

**Non-zero DC offset, muffled sound.** The sample format is being misread: Int16 versus
Float32, byte order, or channel interleaving.

**Clipping.** Either the input level is too high, or the tracks were summed without
headroom. Mixing the tracks is separately forbidden by `CLAUDE.md`.

## Rules

One measurement before the change and one after — otherwise there is no way to tell what
the change did. Compiling, an error-free log, and a file of plausible size are not
evidence.

If a hypothesis about the cause isn't confirmed by measurement, don't move on to the next
fix silently: a wrong hypothesis left in the code "just in case" later reads as a
deliberate decision.

## What to report

Numbers for both tracks before and after, the named cause, the fix, and the measurement
that confirms it. Separately: what remains untested — Bluetooth headset, device switched
mid-recording, multiple simultaneous audio sources, long recordings.
