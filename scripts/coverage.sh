#!/usr/bin/env bash
# Line coverage for both halves of the project, written as lcov and printed as a percentage.
#
# Deliberately two reports rather than one. `Packages/TalkloomCore` is the half that can be
# verified without hardware, and it is measured by its own tests; the app target is mostly
# CoreAudio, and the tests that reach it need a microphone and are excluded here by the same
# scheme that excludes them from the gate. A single figure over both would average a number
# that means something with a number that cannot, and the average would read as a target.
#
# Not part of scripts/check.sh: instrumentation makes the build slower, and coverage is a
# measurement rather than a gate. CI runs this after the gate has passed.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT=coverage
rm -rf "$OUT"
mkdir -p "$OUT"

# Anything under a test directory or a build directory is machinery, not the subject.
IGNORE='(/Tests/|/\.build/|/DerivedData/|/build-|/Developer/)'

percent() { # percent <lcov file>
    awk -F: '/^DA:/ { total++; if ($2 ~ /,[1-9]/) hit++ } END {
        if (total) printf "%.1f%% (%d/%d lines)\n", hit * 100 / total, hit, total
        else print "no data" }' "$1"
}

echo "==> TalkloomCore"
swift test --package-path Packages/TalkloomCore --enable-code-coverage >/dev/null
bin=$(swift build --package-path Packages/TalkloomCore --show-bin-path 2>/dev/null)
xcrun llvm-cov export -format=lcov \
    "$bin/TalkloomCorePackageTests.xctest/Contents/MacOS/TalkloomCorePackageTests" \
    -instr-profile "$bin/codecov/default.profdata" \
    -ignore-filename-regex="$IGNORE" >"$OUT/core.lcov"
percent "$OUT/core.lcov"

echo "==> Talkloom.app"
xcodegen generate --quiet
xcodebuild -project Talkloom.xcodeproj -scheme Talkloom -configuration Debug \
    -derivedDataPath build-coverage -enableCodeCoverage YES test >/dev/null 2>&1
profile=$(find build-coverage/Build/ProfileData -name Coverage.profdata | head -1)
# The app links TalkloomCore, so its report would carry the package's files as well and
# Codecov would count them twice. The package owns its own measurement; this one owns the app.
xcrun llvm-cov export -format=lcov \
    build-coverage/Build/Products/Debug/Talkloom.app/Contents/MacOS/Talkloom \
    -instr-profile "$profile" \
    -ignore-filename-regex="$IGNORE|/Packages/" >"$OUT/app.lcov"
percent "$OUT/app.lcov"
