#!/usr/bin/env bash
# Runs the interactive output-device restart check and removes every artifact even when the
# test host crashes. The Swift test's defer handles ordinary failures; this parent process
# owns the stronger cleanup guarantee because a SIGSEGV cannot run Swift cleanup code.
set -euo pipefail

cd "$(dirname "$0")/.."

recording_root=/tmp/TalkloomDeviceSwitchRecording
run_root=$(mktemp -d /tmp/TalkloomDeviceSwitchRun.XXXXXX)
marker="$run_root/start.marker"
result_bundle="$run_root/result.xcresult"
log="$run_root/xcodebuild.log"
temp_root=${TMPDIR:-/tmp}
temp_root=${temp_root%/}

case "$run_root" in
    /tmp/TalkloomDeviceSwitchRun.*) ;;
    *) echo "unexpected run directory: $run_root" >&2; exit 2 ;;
esac
case "$recording_root" in
    /tmp/TalkloomDeviceSwitchRecording) ;;
    *) echo "unexpected recording directory: $recording_root" >&2; exit 2 ;;
esac
case "$temp_root" in
    /tmp | /var/folders/*/T) ;;
    *) echo "unexpected temporary directory: $temp_root" >&2; exit 2 ;;
esac

touch "$marker"

remove_recording() {
    if [ -d "$recording_root" ]; then
        rm -rf -- "$recording_root"
    fi
}

# shellcheck disable=SC2329 # invoked indirectly by the traps below
cleanup() {
    local status=$?
    trap - EXIT INT TERM

    # These phrases identify only helpers created by this test. A crashed test host cannot
    # reap them itself, while killing every `say` or `afplay` process could stop the user's
    # unrelated audio.
    pkill -f '^/usr/bin/say -r 165 Before the device switch\.' 2>/dev/null || true
    pkill -f '^/usr/bin/say -r 145 Switch the output device now' 2>/dev/null || true
    pkill -f '^/usr/bin/say -r 165 After the device switch\.' 2>/dev/null || true
    pkill -f '^/usr/bin/afplay .*Talkloom-system-probe-' 2>/dev/null || true

    while IFS= read -r probe; do
        case "$probe" in
            "$temp_root"/Talkloom-system-probe-*.wav) rm -f -- "$probe" ;;
        esac
    done < <(
        find "$temp_root" -maxdepth 1 -type f -name 'Talkloom-system-probe-*.wav' \
            -newer "$marker" -print
    )

    remove_recording
    rm -rf -- "$run_root"
    exit "$status"
}
trap cleanup EXIT INT TERM

# A previous crashed run owns this exact project-specific directory. Clearing it before the
# next run makes the harness safe to invoke twice after failure.
remove_recording
pkill -f 'Talkloom.app/Contents/MacOS/Talkloom' 2>/dev/null || true
xcodegen generate --quiet

set +e
xcodebuild -project Talkloom.xcodeproj -scheme TalkloomDeviceSwitchTests \
    -derivedDataPath build -resultBundlePath "$result_bundle" test \
    '-only-testing:TalkloomTests/DeviceTests/Controller/outputDeviceSwitchPreservesBothLogicalTracks()' \
    2>&1 | tee "$log"
test_status=${PIPESTATUS[0]}
set -e

if [ "$test_status" -ne 0 ] && [ -d "$result_bundle" ]; then
    xcrun xcresulttool get test-results summary --path "$result_bundle" || true
fi

exit "$test_status"
