#!/usr/bin/env bash
# Write a reference transcript beside a WAV using the cloud engine.
#
# docs/asr-evaluation.md states when this is legitimate and what it may not be used for. The
# sidecar exists because a generated reference belongs to exactly the audio it came from: it
# names the engine, the model and the audio's checksum, so a reference left beside regenerated
# audio is detectable instead of quietly wrong.
#
# Usage: scripts/generate-asr-reference.sh [--force] AUDIO.wav [AUDIO.wav...]
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/openrouter-credential.sh
. scripts/openrouter-credential.sh

force=false
if [ "${1:-}" = "--force" ]; then
    force=true
    shift
fi
if [ $# -eq 0 ]; then
    echo "Usage: scripts/generate-asr-reference.sh [--force] AUDIO.wav [AUDIO.wav...]" >&2
    exit 2
fi

if [ ! -x scripts/.venv/bin/python ]; then
    echo "scripts/.venv is missing — run uv sync --project scripts" >&2
    exit 127
fi

swift build --package-path Packages/TranscriberCore --product OpenRouterASREval >/dev/null
binary="$(swift build --package-path Packages/TranscriberCore --show-bin-path)/OpenRouterASREval"

for audio in "$@"; do
    if [ ! -f "$audio" ]; then
        echo "$audio does not exist" >&2
        exit 1
    fi
    reference="${audio%.*}.txt"
    sidecar="${audio%.*}.reference.json"
    if [ -e "$reference" ] && [ "$force" != true ]; then
        echo "$reference already exists — pass --force to replace it" >&2
        exit 1
    fi

    report=$(mktemp)
    trap 'rm -f "$report"' EXIT
    if ! "$binary" "$audio" >"$report"; then
        echo "transcription failed for $audio" >&2
        exit 1
    fi

    checksum=$(shasum -a 256 "$audio" | cut -d' ' -f1)
    generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    TRANSCRIBER_AUDIO="$audio" \
    TRANSCRIBER_REFERENCE="$reference" \
    TRANSCRIBER_SIDECAR="$sidecar" \
    TRANSCRIBER_CHECKSUM="$checksum" \
    TRANSCRIBER_GENERATED_AT="$generated_at" \
        scripts/.venv/bin/python - "$report" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
result = report["result"]
text = " ".join(segment["text"] for segment in result["segments"]).strip()

with open(os.environ["TRANSCRIBER_REFERENCE"], "w", encoding="utf-8") as handle:
    handle.write(text + "\n")

sidecar = {
    "audio": os.path.basename(os.environ["TRANSCRIBER_AUDIO"]),
    "audioSHA256": os.environ["TRANSCRIBER_CHECKSUM"],
    "engine": "OpenRouterASREval",
    "model": result["model"],
    "generatedAt": os.environ["TRANSCRIBER_GENERATED_AT"],
    "note": "Machine-generated reference. See docs/asr-evaluation.md for what it may score.",
}
with open(os.environ["TRANSCRIBER_SIDECAR"], "w", encoding="utf-8") as handle:
    json.dump(sidecar, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")

print(f"  {os.environ['TRANSCRIBER_REFERENCE']}: {len(text.split())} words")
PY
    rm -f "$report"
    trap - EXIT
done
