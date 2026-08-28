#!/usr/bin/env bash
# What this machine actually provides, printed rather than assumed.
#
# The alternative is a paragraph in AGENTS.md listing versions, which is a copy of a fact
# that changes without the copy being updated — the failure this project has already had
# with a deployment floor. Ask the machine instead.
#
# Exits non-zero when something required is missing, and says how to get it. Run it on a
# fresh checkout, and when a build fails in a way that smells like the environment rather
# than the code.
set -uo pipefail

# Deliberately no `set -e` — this script reports every missing tool rather than stopping at
# the first. That makes the one unchecked failure below matter: without `|| exit`, a cd that
# fails would leave it describing whatever directory it happened to start in.
cd "$(dirname "$0")/.." || exit 1

missing=0

report() { printf '  %-18s %s\n' "$1" "$2"; }

need() { # need <label> <fix hint> <command...>
    local label=$1 hint=$2
    shift 2
    local value
    if value=$("$@" 2>/dev/null | head -1) && [ -n "$value" ]; then
        report "$label" "$value"
    else
        report "$label" "MISSING — $hint"
        missing=1
    fi
}

echo "platform"
report "macOS" "$(sw_vers -productVersion) ($(uname -m))"
# project.yml owns the deployment target; printing it here keeps the number out of prose.
report "deployment target" "$(sed -n 's/^ *macOS: *"\(.*\)"/\1/p' project.yml | head -1) (project.yml)"

echo "toolchain"
# The build skill's first failure mode: only Command Line Tools are selected, so xcodebuild
# is absent or unlicensed. The selected developer directory is what distinguishes them.
report "developer dir" "$(xcode-select -p 2>/dev/null || echo 'MISSING')"
case "$(xcode-select -p 2>/dev/null)" in
    *Xcode.app*) ;;
    *)
        report "" "not Xcode — sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        missing=1
        ;;
esac
need "xcodebuild" "install Xcode from the App Store" xcodebuild -version
need "swift" "comes with Xcode" swift --version
report "macOS SDK" "$(xcrun --show-sdk-version 2>/dev/null || echo 'MISSING')"
# swift-format is reached through xcrun, never from Homebrew: a second copy would be a
# second opinion about formatting.
need "swift-format" "comes with Xcode" xcrun swift-format --version

echo "command line"
need "xcodegen" "brew bundle" xcodegen --version
need "xcsift" "brew bundle" xcsift --version
need "uv" "brew bundle" uv --version
need "ffmpeg" "brew bundle (evaluation tooling only)" ffmpeg -version
need "afconvert" "ships with macOS" xcrun --find afconvert

echo "signing"
# TCC binds a grant to the bundle's signature, so this certificate is what lets granted
# permissions survive a rebuild. Ad-hoc signing does not.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Transcriber Dev"; then
    report "Transcriber Dev" "present"
else
    report "Transcriber Dev" "MISSING — scripts/make-signing-cert.sh"
    missing=1
fi

echo "python tooling"
if [ -x scripts/.venv/bin/python ]; then
    report "venv" "$(scripts/.venv/bin/python --version 2>&1)"
    for module in numpy soundfile jiwer; do
        if scripts/.venv/bin/python -c "import $module" 2>/dev/null; then
            report "$module" "importable"
        else
            report "$module" "MISSING — uv sync --project scripts"
            missing=1
        fi
    done
else
    report "venv" "MISSING — uv sync --project scripts"
    missing=1
fi

echo
if [ "$missing" -ne 0 ]; then
    echo "something above is missing; the hints say where it comes from" >&2
    exit 1
fi
echo "everything this project needs is present"
