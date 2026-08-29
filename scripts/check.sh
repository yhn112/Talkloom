#!/usr/bin/env bash
# The project's one gate: everything that can be verified without a microphone. Each
# numbered step below states what it protects against. One line per step, non-zero exit on
# the first failure, so an agent can treat it as the definition of "done" for anything short
# of a real recording.
#
# What a green run here does not establish — and why capture correctness still takes a real
# recording — is in AGENTS.md, "What counts as verified".
set -euo pipefail

cd "$(dirname "$0")/.."

for tool in xcsift zizmor; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool is missing — install it with: brew bundle" >&2
        exit 127
    fi
done

step() { printf '%-12s' "$1"; }
ok() { echo "ok${1:+   $1}"; }
fail() { echo "FAILED"; }

# 1. The .xcodeproj is generated, and XcodeGen builds the source list from the filesystem.
# A file added but never generated in is simply not compiled, which looks like a change
# that had no effect rather than like an error.
step generate
xcodegen generate --quiet
ok

# 2. The instructions. Roles, skills and adapters are read as authoritative and fail
# silently when they go stale, so the mechanical half of that is checked here: no
# duplicated version literals, no dangling paths, no roster drift between the clients.
step docs
if docs_problems=$(python3 scripts/check_docs.py 2>&1); then
    ok
else
    fail
    echo "$docs_problems" | sed 's/^/  /'
    exit 1
fi

# 3. The workflows. A broken one turns CI red and announces itself; the failures worth a
# gate are the quiet ones — an action pinned to a tag its owner can move, a token left in
# .git/config for any later step to package up, an expression that splices untrusted input
# into a shell. None of those ever fail a run. --offline because a gate that needs the
# network is a gate that fails on a train.
step workflows
if ! workflow_problems=$(zizmor --offline --quiet .github/workflows/ 2>&1); then
    fail
    echo "$workflow_problems" | sed 's/^/  /'
    exit 1
fi
ok

# 4. The evaluation tooling. Python front ends must still import and parse their arguments;
# shell entry points must still parse. An edit then fails here rather than when someone
# reaches for the tool mid-diagnosis. scripts/.venv is a derived local artifact, so a missing one
# is skipped rather than failed — `uv sync --project scripts` creates it.
#
# One file per call, and every file. `bash -n a.sh b.sh` parses only a.sh — b.sh becomes its
# $1 — so the two-argument form this used to have exited zero without ever reading the second
# script, and nine of the eleven were not named at all.
step tools
shell_problems=""
for script in scripts/*.sh; do
    problem=$(bash -n "$script" 2>&1) || shell_problems="${shell_problems}${problem}
"
done
if [ -n "$shell_problems" ]; then
    fail
    printf '%s' "$shell_problems" | sed 's/^/  /'
    exit 1
fi
if ! git check-ignore -q .openrouter.apikey; then
    fail
    echo "  .openrouter.apikey must stay ignored by git"
    exit 1
fi
# The guard above, and openrouter-credential.sh, both protect the credential by file name.
# A key pasted into a source file, a document or a fixture is caught by neither, and the
# repository is public. GitHub scans pushes for the provider formats it recognises, but the
# non-provider patterns that would cover an unrecognised one need a licence this repository
# does not have — checked, and the API accepts the request and ignores it — so the generic
# half belongs here.
#
# Every pattern is written so that it cannot match this file: each requires a run of key
# characters exactly where the literal has a bracket. Simplifying that away makes the gate
# fail on itself, permanently.
if leaked=$(git grep -nIE 'sk-or-v1-[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{32,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----'); then
    fail
    echo "  a credential appears in a tracked file:"
    echo "$leaked" | sed 's/^/    /'
    exit 1
fi
if [ -x scripts/.venv/bin/python ]; then
    broken=""
    for script in wer audio_check track_compare; do
        scripts/.venv/bin/python "scripts/$script.py" --help >/dev/null 2>&1 || broken="$broken $script.py"
    done
    if [ -z "$broken" ]; then
        ok
    else
        fail
        echo "  will not start:$broken"
        echo "  run scripts/doctor.sh"
        exit 1
    fi
else
    ok "skipped, no scripts/.venv"
fi

# 5. Formatting. swift-format has no --check mode, so the tree is formatted into a copy and
# compared: a file that the formatter would change is a file that is not formatted.
# Comparing output rather than running `lint --strict` is deliberate — a Logger message is
# one string literal, the formatter cannot break it, and the resulting over-long line would
# fail a linter forever with no possible fix.
step format
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
rsync -a --exclude=.build Sources Tests Packages "$scratch/"
xcrun swift-format format --configuration .swift-format --parallel --in-place \
    --recursive "$scratch/Sources" "$scratch/Tests" "$scratch/Packages"
if unformatted=$(for tree in Sources Tests Packages; do
    diff -rq --exclude=.build "$tree" "$scratch/$tree"
done); then
    ok
else
    fail
    echo "$unformatted" | sed -E 's|^Files ([^ ]+) and .*|  \1|'
    echo "  run scripts/format.sh"
    exit 1
fi

# 6. The package's own tests. They need no signing, no test host and no hardware, so they
# run first and in about a second: a broken WAV header should not cost a full app build to
# discover.
step package
if summary=$(swift test --package-path Packages/TalkloomCore 2>&1 | xcsift -f toon -w -E) \
    && swift build --package-path Packages/TalkloomCore --product OpenRouterASREval >/dev/null \
    && probe_directory=$(swift build --package-path Packages/TalkloomCore --show-bin-path) \
    && "$probe_directory/OpenRouterASREval" --help >/dev/null; then
    ok "$(echo "$summary" | awk '/passed_tests:/ {print $2" tests"}')"
else
    fail
    echo "$summary" | sed 's/^/  /'
    exit 1
fi

# 7. Build and tests. Device tests live in their own scheme and are skipped here: they need
# a microphone and make audible noise. xcsift collapses xcodebuild's output — measured at
# 98 kB for a green run against 127 bytes — while -E preserves the failure exit code, which
# the pipeline would otherwise swallow.
step build+test
if summary=$(xcodebuild -project Talkloom.xcodeproj -scheme Talkloom \
    -configuration Debug -derivedDataPath build test 2>&1 | xcsift -f toon -w -E); then
    ok "$(echo "$summary" | awk '/passed_tests:/ {t=$2} /warnings:/ {w=$2} END {print t" tests, "w" warnings"}')"
else
    fail
    echo "$summary" | sed 's/^/  /'
    exit 1
fi
