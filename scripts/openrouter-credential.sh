#!/usr/bin/env bash
# Sourced, not run. Proves the local OpenRouter key exists and cannot be committed, and keeps
# it out of every subprocess but the evaluator, which reads the fixed file itself.
#
# This lives on its own because more than one script needs the same guard, and a guard that
# exists in two copies is a guard that will be relaxed in one of them.

credential_file=.openrouter.apikey
if [ ! -s "$credential_file" ]; then
    echo "$credential_file is missing or empty" >&2
    exit 2
fi
if ! git check-ignore -q -- "$credential_file"; then
    echo "$credential_file is not ignored by git — refusing to use a committable key" >&2
    exit 2
fi
unset OPENROUTER_API_KEY
