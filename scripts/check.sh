#!/usr/bin/env bash
# The project's one gate: everything that can be verified without a microphone.
#
# Regenerates the project, checks the instructions for drift, checks that the Python
# tooling starts, checks formatting, builds, and runs the tests that need no hardware. Prints one line per step and exits non-zero on the first failure, so an agent
# can treat it as the definition of "done" for anything short of a real recording.
#
# What this deliberately does NOT cover: capture correctness. A green run here is
# compatible with a valid WAV full of silence. That still takes a real recording — the
# `TranscriberDeviceTests` scheme and the `audio-doctor` skill.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcsift >/dev/null; then
    echo "xcsift is missing — install it with: brew install xcsift" >&2
    exit 127
fi

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

# 3. The evaluation tooling. Python front ends must still import and parse their arguments;
# shell entry points must still parse. An edit then fails here rather than when someone
# reaches for the tool mid-diagnosis. .venv is a derived local artifact, so a missing one is
# skipped rather than failed — `uv sync` creates it.
step tools
if ! shell_problems=$(
    bash -n scripts/generate-asr-smoke-fixtures.sh scripts/openrouter-asr-eval.sh 2>&1
); then
    fail
    echo "$shell_problems" | sed 's/^/  /'
    exit 1
fi
if ! git check-ignore -q .openrouter.apikey; then
    fail
    echo "  .openrouter.apikey must stay ignored by git"
    exit 1
fi
if [ -x .venv/bin/python ]; then
    broken=""
    for script in wer audio_check track_compare; do
        .venv/bin/python "scripts/$script.py" --help >/dev/null 2>&1 || broken="$broken $script.py"
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
    ok "skipped, no .venv"
fi

# 4. Formatting. swift-format has no --check mode, so the tree is formatted into a copy and
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

# 5. The package's own tests. They need no signing, no test host and no hardware, so they
# run first and in about a second: a broken WAV header should not cost a full app build to
# discover.
step package
if summary=$(swift test --package-path Packages/TranscriberCore 2>&1 | xcsift -f toon -w -E) \
    && swift build --package-path Packages/TranscriberCore --product OpenRouterASREval >/dev/null \
    && probe_directory=$(swift build --package-path Packages/TranscriberCore --show-bin-path) \
    && "$probe_directory/OpenRouterASREval" --help >/dev/null; then
    ok "$(echo "$summary" | awk '/passed_tests:/ {print $2" tests"}')"
else
    fail
    echo "$summary" | sed 's/^/  /'
    exit 1
fi

# 6. Build and tests. Device tests live in their own scheme and are skipped here: they need
# a microphone and make audible noise. xcsift collapses xcodebuild's output — measured at
# 98 kB for a green run against 127 bytes — while -E preserves the failure exit code, which
# the pipeline would otherwise swallow.
step build+test
if summary=$(xcodebuild -project Transcriber.xcodeproj -scheme Transcriber \
    -configuration Debug -derivedDataPath build test 2>&1 | xcsift -f toon -w -E); then
    ok "$(echo "$summary" | awk '/passed_tests:/ {t=$2} /warnings:/ {w=$2} END {print t" tests, "w" warnings"}')"
else
    fail
    echo "$summary" | sed 's/^/  /'
    exit 1
fi
