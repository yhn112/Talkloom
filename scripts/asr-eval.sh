#!/usr/bin/env bash
# Run the ASR fixtures through one evaluator product and write a comparable report bundle.
#
# The engine-specific part is the evaluator binary and whatever its wrapper had to check
# before calling here; everything below — fixture selection, timing, memory, hypothesis
# extraction and metrics — is the same measurement whichever engine produced the text, and
# lives here once so two engines cannot be measured two different ways.
#
# Usage: scripts/asr-eval.sh PRODUCT [fixture...]
set -euo pipefail

cd "$(dirname "$0")/.."

if [ $# -lt 1 ]; then
    echo "Usage: scripts/asr-eval.sh PRODUCT [fixture...]" >&2
    exit 2
fi
product=$1
shift

if [ ! -x .venv/bin/python ]; then
    echo ".venv is missing — run uv sync" >&2
    exit 127
fi

fixtures=("$@")
if [ ${#fixtures[@]} -eq 0 ]; then
    fixtures=(ru_short en_short mixed_short ru_terms long_pause silence)
fi

run_id=${TRANSCRIBER_ASR_RUN_ID:-"$product-$(date -u +%Y%m%dT%H%M%SZ)"}
report_directory="Tests/reports/$run_id"

swift build --package-path Packages/TranscriberCore --product "$product" >/dev/null
binary_directory=$(swift build --package-path Packages/TranscriberCore --show-bin-path)
binary="$binary_directory/$product"

mkdir -p Tests/reports
if ! mkdir "$report_directory" 2>/dev/null; then
    echo "$report_directory already exists — choose a new TRANSCRIBER_ASR_RUN_ID" >&2
    exit 1
fi

failure_count=0
for fixture in "${fixtures[@]}"; do
    audio="Tests/fixtures/$fixture.wav"
    reference="Tests/fixtures/$fixture.txt"
    report="$report_directory/$fixture.json"
    hypothesis="$report_directory/$fixture.txt"
    runtime="$report_directory/$fixture.runtime.txt"

    if [ ! -f "$audio" ] || [ ! -f "$reference" ]; then
        echo "$fixture is incomplete — run scripts/generate-asr-smoke-fixtures.sh" >&2
        exit 1
    fi

    echo "evaluating $fixture"
    if ! /usr/bin/time -l "$binary" "$audio" >"$report" 2>"$runtime"; then
        failed_runtime="$report_directory/$fixture.failed.txt"
        mv "$runtime" "$failed_runtime"
        rm -f "$report"
        sed 's/^/  /' "$failed_runtime" >&2
        failure_count=$((failure_count + 1))
        continue
    fi

    .venv/bin/python - "$report" "$hypothesis" <<'PY'
import json
import sys

report_path, hypothesis_path = sys.argv[1:]
with open(report_path, encoding="utf-8") as handle:
    report = json.load(handle)
segments = report["result"]["segments"]
with open(hypothesis_path, "w", encoding="utf-8") as handle:
    handle.write(" ".join(segment["text"] for segment in segments).strip())
    handle.write("\n")
usage = report["result"].get("usage") or {}
cost = usage.get("cost")
cost_text = "unknown" if cost is None else f"${cost:.6f}"
print(
    f"  duration {report['audioDurationSeconds']:.3f}s, "
    f"elapsed {report['elapsedSeconds']:.3f}s, "
    f"xRT {report['realTimeFactor']:.3f}, cost {cost_text}"
)
PY

    peak_bytes=$(awk '/maximum resident set size/ { value=$1 } END { print value }' "$runtime")
    if [ -n "$peak_bytes" ]; then
        awk -v bytes="$peak_bytes" 'BEGIN { printf "  peak memory %.1f MiB\n", bytes / 1048576 }'
    fi

    if [ -n "$(tr -d '[:space:]' <"$reference")" ]; then
        .venv/bin/python scripts/wer.py \
            --ref "$reference" --hyp "$hypothesis" --align \
            | tee "$report_directory/$fixture.metrics.txt"
    elif [ -n "$(tr -d '[:space:]' <"$hypothesis")" ]; then
        echo "  silence hallucination: $(tr '\n' ' ' <"$hypothesis")" \
            | tee "$report_directory/$fixture.metrics.txt"
    else
        echo "  silence: no text" | tee "$report_directory/$fixture.metrics.txt"
    fi
done

echo "reports written to $report_directory"
if [ "$failure_count" -gt 0 ]; then
    echo "$failure_count fixture(s) failed; see the .failed.txt diagnostics" >&2
    exit 1
fi
