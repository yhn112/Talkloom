#!/usr/bin/env bash
# Run the ASR fixtures through the live OpenRouter boundary. This wrapper owns only what is
# specific to a paid cloud engine — proving the local key exists and cannot be committed, and
# keeping it out of every other subprocess. The measurement itself is scripts/asr-eval.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

credential_file=.openrouter.apikey
if [ ! -s "$credential_file" ]; then
    echo "$credential_file is missing or empty" >&2
    exit 2
fi
if ! git check-ignore -q -- "$credential_file"; then
    echo "$credential_file is not ignored by git — refusing to use a committable key" >&2
    exit 2
fi
# The evaluator reads the fixed file itself. No other subprocess receives the credential.
unset OPENROUTER_API_KEY

exec scripts/asr-eval.sh OpenRouterASREval "$@"
