#!/usr/bin/env python3
"""Inspect recorded tracks for what file duration cannot reveal.

The signature failure of audio capture is a valid file of the correct duration
containing nothing but zeros. This script reports amplitude, silence, DC offset,
clipping, and deviations from the project's canonical format (16 kHz mono).

    scripts/audio_check.py Recordings/mic.wav Recordings/system.wav

A non-zero exit status means at least one file looks broken.
"""

from __future__ import annotations

import argparse
import math
import sys

import numpy as np
import soundfile as sf

EXPECTED_RATE = 16_000
EXPECTED_CHANNELS = 1

# Below this peak a track is effectively silence: inaudible, and useless for ASR.
SILENCE_PEAK_DBFS = -60.0
# Pauses are normal in a meeting, but 98% silence means the track is essentially empty.
SUSPICIOUS_SILENT_RATIO = 0.98


def dbfs(value: float) -> float:
    """Convert an amplitude in [0, 1] to dBFS. Zero maps to -inf."""
    if value <= 0.0:
        return -math.inf
    return 20.0 * math.log10(value)


def fmt_db(value: float) -> str:
    return "-inf" if value == -math.inf else f"{value:6.1f}"


def analyse(path: str) -> list[str]:
    """Return a list of problems; an empty list means the file looks healthy."""
    problems: list[str] = []

    data, rate = sf.read(path, dtype="float32", always_2d=True)
    frames, channels = data.shape
    duration = frames / rate if rate else 0.0

    if frames == 0:
        print(f"{path}: file is empty (0 frames)")
        return [f"{path}: no data"]

    peak = float(np.abs(data).max())
    rms = float(np.sqrt(np.mean(np.square(data))))
    dc_offset = float(np.abs(data.mean()))

    # Silence is measured over 20 ms windows — the same way VAD sees it.
    window = max(1, int(rate * 0.02))
    usable = frames - (frames % window)
    mono = data.mean(axis=1)[:usable]
    windows = mono.reshape(-1, window)
    window_peaks = np.abs(windows).max(axis=1)
    silent_ratio = float((window_peaks < 10 ** (SILENCE_PEAK_DBFS / 20)).mean())

    # Clipping: samples pinned against the top of the scale.
    clipped = int((np.abs(data) >= 0.999).sum())

    print(f"{path}")
    print(f"    format      {rate} Hz, {channels} ch, {duration:.2f} s ({frames} frames)")
    print(f"    peak        {fmt_db(dbfs(peak))} dBFS   (linear {peak:.4f})")
    print(f"    RMS         {fmt_db(dbfs(rms))} dBFS")
    print(f"    silence     {silent_ratio * 100:.1f}% of 20 ms windows")
    print(f"    DC offset   {dc_offset:.5f}")
    if clipped:
        print(f"    clipping    {clipped} samples")

    if dbfs(peak) < SILENCE_PEAK_DBFS:
        problems.append(f"{path}: track is empty — peak {fmt_db(dbfs(peak))} dBFS")
    elif silent_ratio > SUSPICIOUS_SILENT_RATIO:
        problems.append(f"{path}: {silent_ratio * 100:.1f}% silence, almost no signal")

    if rate != EXPECTED_RATE:
        problems.append(f"{path}: {rate} Hz instead of {EXPECTED_RATE} Hz")
    if channels != EXPECTED_CHANNELS:
        problems.append(f"{path}: {channels} channels instead of {EXPECTED_CHANNELS}")
    if clipped > frames * 0.001:
        problems.append(f"{path}: clipping on {clipped} samples, input level too high")
    if dc_offset > 0.01:
        problems.append(f"{path}: DC offset {dc_offset:.4f}, sample format misread")

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", help="audio files (wav, caf, aiff)")
    args = parser.parse_args()

    problems: list[str] = []
    for path in args.files:
        try:
            problems.extend(analyse(path))
        except Exception as exc:  # noqa: BLE001 — report and continue to the next file
            problems.append(f"{path}: could not read — {exc}")
        print()

    if problems:
        print("Problems:")
        for problem in problems:
            print(f"  x {problem}")
        return 1

    print("All tracks look healthy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
