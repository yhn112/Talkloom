#!/usr/bin/env python3
"""Compute WER and CER between a reference transcript and an ASR hypothesis.

Without normalization the metric mostly measures punctuation and casing rather than
recognition, so texts are normalized by default: lowercased, ё collapsed to е,
punctuation stripped, whitespace collapsed.

    scripts/wer.py --ref tests/fixtures/ru_meeting.txt --hyp out/ru_meeting.hyp.txt
    scripts/wer.py --ref-text "hello world" --hyp-text "hello word"
"""

from __future__ import annotations

import argparse
import re
import sys
import unicodedata

import jiwer

# Punctuation is dropped entirely: ASR engines place it by their own conventions, and
# penalizing that when comparing models measures the wrong thing.
_PUNCT = re.compile(r"[^\w\s]", flags=re.UNICODE)
_SPACES = re.compile(r"\s+", flags=re.UNICODE)


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower()
    # ё and е are written differently but sound alike; Whisper picks between them at random.
    text = text.replace("ё", "е")
    text = _PUNCT.sub(" ", text)
    return _SPACES.sub(" ", text).strip()


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", help="file holding the reference transcript")
    parser.add_argument("--hyp", help="file holding the ASR hypothesis")
    parser.add_argument("--ref-text", help="reference as a literal string")
    parser.add_argument("--hyp-text", help="hypothesis as a literal string")
    parser.add_argument(
        "--raw",
        action="store_true",
        help="skip normalization (measure punctuation and casing too)",
    )
    parser.add_argument(
        "--align",
        action="store_true",
        help="print the alignment with errors highlighted",
    )
    args = parser.parse_args()

    reference = args.ref_text if args.ref_text is not None else read(args.ref) if args.ref else None
    hypothesis = args.hyp_text if args.hyp_text is not None else read(args.hyp) if args.hyp else None

    if reference is None or hypothesis is None:
        parser.error("need --ref/--hyp or --ref-text/--hyp-text")

    if not args.raw:
        reference, hypothesis = normalize(reference), normalize(hypothesis)

    if not reference.strip():
        print("reference is empty — cannot compute the metric", file=sys.stderr)
        return 2

    words = jiwer.process_words(reference, hypothesis)
    cer = jiwer.cer(reference, hypothesis)

    ref_words = len(reference.split())
    print(f"WER  {words.wer * 100:6.2f}%   ({ref_words} reference words)")
    print(f"CER  {cer * 100:6.2f}%")
    print(
        f"substitutions {words.substitutions}, "
        f"deletions {words.deletions}, "
        f"insertions {words.insertions}"
    )

    # Many insertions alongside few substitutions is the signature of Whisper
    # hallucinating on silence: it writes text that was never in the audio.
    if words.insertions > max(3, ref_words * 0.15):
        print("\nWarning: unusually many insertions — check VAD and hallucinations on silence")

    if args.align:
        print()
        print(jiwer.visualize_alignment(words, show_measures=False))

    return 0


if __name__ == "__main__":
    sys.exit(main())
