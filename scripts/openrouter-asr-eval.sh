#!/usr/bin/env bash
# Run the ASR fixtures through the live OpenRouter boundary. The measurement itself is
# scripts/asr-eval.sh; this wrapper only adds what a paid cloud engine needs.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/openrouter-credential.sh
. scripts/openrouter-credential.sh

exec scripts/asr-eval.sh OpenRouterASREval "$@"
