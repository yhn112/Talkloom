#!/usr/bin/env python3
"""Compare a recording's two tracks against each other.

`audio_check.py` asks whether each track is healthy on its own. This asks the
questions that only make sense across both: how far apart they started, how much
of the system audio leaked into the microphone, and whether echo cancellation is
cutting into the near speaker as well as the far one.

    scripts/track_compare.py ~/Library/Application\\ Support/Transcriber/Recordings/2026-08-24_20-29-44

The session's `session.json` supplies the offset between the tracks; without it
the two files cannot be put on one timeline, since nothing in the audio says so.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

# A 20 ms window is how VAD sees the signal, and short enough to follow speech.
WINDOW_SECONDS = 0.02
# Below this a window counts as silence for the purpose of finding who is talking.
ACTIVE_DBFS = -50.0


def dbfs(value: float) -> float:
    return 20.0 * math.log10(value) if value > 0 else -math.inf


def fmt(value: float) -> str:
    return "  -inf" if value == -math.inf else f"{value:6.1f}"


def rms_dbfs(samples: np.ndarray) -> float:
    if samples.size == 0:
        return -math.inf
    return dbfs(float(np.sqrt(np.mean(np.square(samples.astype(np.float64))))))


def envelope(samples: np.ndarray, window: int) -> np.ndarray:
    usable = samples.size - (samples.size % window)
    if usable == 0:
        return np.zeros(0)
    return np.sqrt(np.mean(np.square(samples[:usable].reshape(-1, window)), axis=1))


def load(session: Path) -> tuple[dict, dict[str, np.ndarray], int]:
    manifest = json.loads((session / "session.json").read_text())
    tracks, rate = {}, None
    for entry in manifest["tracks"]:
        data, file_rate = sf.read(session / entry["file"], dtype="float32", always_2d=True)
        if rate is None:
            rate = file_rate
        elif file_rate != rate:
            raise SystemExit(f"tracks differ in sample rate: {rate} vs {file_rate}")
        # Pad the front by the track's own offset so index 0 is the same instant in both.
        if entry["startOffset"] is None:
            raise SystemExit(f"{entry['file']} has no first-sample timestamp and cannot be aligned")
        lead = int(round(entry["startOffset"] * file_rate))
        tracks[entry["file"]] = np.concatenate([np.zeros(lead, dtype="float32"), data.mean(axis=1)])
    length = max(track.size for track in tracks.values())
    for name, track in tracks.items():
        tracks[name] = np.concatenate([track, np.zeros(length - track.size, dtype="float32")])
    return manifest, tracks, rate


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path, help="a recording directory containing session.json")
    parser.add_argument("--near", default="mic.wav", help="the track carrying the local speaker")
    parser.add_argument("--far", default="system.wav", help="the track carrying everyone else")
    args = parser.parse_args()

    manifest, tracks, rate = load(args.session)
    if args.near not in tracks or args.far not in tracks:
        raise SystemExit(f"expected {args.near} and {args.far}, found {sorted(tracks)}")
    near, far = tracks[args.near], tracks[args.far]

    print(f"{args.session}")
    for entry in manifest["tracks"]:
        # A recovered session knows how long each track is and nothing else: it was
        # repaired from the files after a crash, and nobody measured a peak, a drop count
        # or an offset. Print that as unknown rather than inventing a zero.
        peak, offset = entry.get("peakAmplitude"), entry.get("startOffset")
        dropped = entry.get("droppedSampleCount")
        print(
            f"    {entry['file']:12} {entry['sampleRate']:.0f} Hz  "
            f"{entry['frameCount'] / entry['sampleRate']:6.2f} s  "
            f"peak {fmt(dbfs(peak)) if peak is not None else '     ?'} dBFS  "
            f"starts at {f'+{offset:.3f} s' if offset is not None else 'unknown '} "
            f"dropped {dropped if dropped is not None else 'unknown'}"
        )

    window = max(1, int(rate * WINDOW_SECONDS))
    near_env, far_env = envelope(near, window), envelope(far, window)
    span = min(near_env.size, far_env.size)
    near_env, far_env = near_env[:span], far_env[:span]
    threshold = 10 ** (ACTIVE_DBFS / 20)
    near_on, far_on = near_env > threshold, far_env > threshold

    def report(label: str, mask: np.ndarray) -> None:
        seconds = float(mask.sum()) * WINDOW_SECONDS
        if seconds == 0:
            print(f"    {label:26}      — never happened")
            return
        near_part = near[: span * window].reshape(-1, window)[mask].ravel()
        far_part = far[: span * window].reshape(-1, window)[mask].ravel()
        zeros = float((near_part == 0).mean()) * 100
        print(
            f"    {label:26} {seconds:6.1f} s   near {fmt(rms_dbfs(near_part))}   "
            f"far {fmt(rms_dbfs(far_part))}   near zeroed {zeros:5.1f}%"
        )

    print("\n  who is talking, and what each track holds while they do")
    report("nobody", ~near_on & ~far_on)
    report("far side only", ~near_on & far_on)
    report("near side only", near_on & ~far_on)
    report("both at once", near_on & far_on)

    far_only = ~near_on & far_on
    quiet = ~near_on & ~far_on
    if far_only.any() and quiet.any():
        columns = near[: span * window].reshape(-1, window)
        leak = rms_dbfs(columns[far_only].ravel())
        floor = rms_dbfs(columns[quiet].ravel())
        far_level = rms_dbfs(far[: span * window].reshape(-1, window)[far_only].ravel())
        print("\n  echo cancellation")
        print(f"    room noise floor                {fmt(floor)} dBFS")
        print(f"    near track while the far side talks {fmt(leak)} dBFS")
        print(f"    echo return loss                {far_level - leak:6.1f} dB")
        if leak > floor + 6:
            print("    x the far side is audible in the near track; expect duplicated lines")

    if (near_on & ~far_on).any() and (near_on & far_on).any():
        columns = near[: span * window].reshape(-1, window)
        alone = rms_dbfs(columns[near_on & ~far_on].ravel())
        together = rms_dbfs(columns[near_on & far_on].ravel())
        print("\n  double talk")
        print(f"    near side alone                 {fmt(alone)} dBFS")
        print(f"    near side over the far side     {fmt(together)} dBFS")
        print(f"    cost of talking over them       {together - alone:6.1f} dB")

    return 0


if __name__ == "__main__":
    sys.exit(main())
