#!/usr/bin/env bash
# The project's one gate: everything that can be verified without a microphone.
#
# Regenerates the project, checks formatting, builds, and runs the tests that need no
# hardware. Prints one line per step and exits non-zero on the first failure, so an agent
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

# 2. Formatting. swift-format has no --check mode, so the tree is formatted into a copy and
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

# 3. The package's own tests. They need no signing, no test host and no hardware, so they
# run first and in about a second: a broken WAV header should not cost a full app build to
# discover.
step package
if summary=$(swift test --package-path Packages/TranscriberCore 2>&1 | xcsift -f toon -w -E); then
    ok "$(echo "$summary" | awk '/passed_tests:/ {print $2" tests"}')"
else
    fail
    echo "$summary" | sed 's/^/  /'
    exit 1
fi

# 4. Build and tests. Device tests live in their own scheme and are skipped here: they need
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
