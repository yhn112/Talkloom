#!/usr/bin/env bash
# The rare run: the hardware-free tests under a sanitizer.
#
# This is not part of `scripts/check.sh`. It takes minutes rather than seconds, and what it
# checks does not change on most commits. Run it after touching the ring buffer, anything
# holding an `Unsafe*Pointer`, or actor isolation on the capture path — and before calling
# such a change done.
#
# Thread and address sanitizers cannot be enabled together, so each is its own run.
#
# Device tests are deliberately out of scope. The `Talkloom` scheme excludes them, and
# that is the point: instrumentation slows the audio callback enough to produce dropouts,
# which would be an artefact of the measurement rather than a finding.
#
# A sanitizer report fails the run — verified against a deliberate race, which exits 65
# with `** TEST FAILED **`. The summary lines are printed here because they are what says
# *which* access raced, and they do not survive xcsift.
set -euo pipefail

cd "$(dirname "$0")/.."

# Its own derived data: objects built with instrumentation must not be reused by an
# ordinary build, and an ordinary build must not satisfy a sanitizer run.
DERIVED=build-san

case "${1:-all}" in
    thread) SANITIZERS=(thread) ;;
    address) SANITIZERS=(address) ;;
    all) SANITIZERS=(thread address) ;;
    *)
        echo "usage: $0 [thread|address|all]" >&2
        exit 2
        ;;
esac

mkdir -p "$DERIVED"
log="$DERIVED/sanitize.log"

run() { # run <label> <command...>
    local label=$1
    shift
    printf '%-22s' "$label"
    if "$@" >"$log" 2>&1; then
        echo "ok"
    else
        echo "FAILED"
        # The sanitizer's own summary first: it names the racing accesses or the bad
        # address, which the surrounding test output does not.
        grep -E "(Thread|Address)Sanitizer: |^SUMMARY: " "$log" | sed 's/^/  /' || true
        # Launching the app under a test host emits a screenful of XPC failures containing
        # the word "error", so match test verdicts and compiler diagnostics specifically
        # rather than anything that looks like one.
        grep -E "✘|^\*\* (TEST|BUILD) FAILED|^[^ ]+:[0-9]+:[0-9]+: error: " "$log" |
            head -20 | sed 's/^/  /' || true
        echo "  full log: $log"
        exit 1
    fi
}

for sanitizer in "${SANITIZERS[@]}"; do
    echo "== $sanitizer sanitizer =="

    run "package" swift test --package-path Packages/TalkloomCore --sanitize="$sanitizer"

    case "$sanitizer" in
        thread) flag=-enableThreadSanitizer ;;
        address) flag=-enableAddressSanitizer ;;
    esac

    run "app (hardware-free)" xcodebuild -project Talkloom.xcodeproj -scheme Talkloom \
        -configuration Debug -derivedDataPath "$DERIVED" test "$flag" YES
done
