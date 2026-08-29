---
name: build
description: Build, sign, and launch Talkloom.app, run the tests, and read the app's logs. Use after code changes, when a change needs checking in the running app, and when the app won't launch or misbehaves. Do not use to diagnose recording quality — that is audio-doctor.
---

# Building, testing, and running

`.xcodeproj` is a generated artifact in this project. The source of truth is
`project.yml`, so the cycle always starts with generation, never with opening the project.

## The short version

```bash
scripts/check.sh
```

Regenerates the project, checks the instructions for drift, checks that the Python tooling
starts, checks formatting, builds, and runs the hardware-free tests — about six seconds, one
line per step, non-zero exit on the first failure. This is the gate `AGENTS.md` requires
before a change is called done. Use it for every ordinary change; the steps below are for
when something needs to be done by hand, and for running the app.

If it reports a formatting failure, `scripts/format.sh` fixes it. If it reports a `docs`
failure, the instructions name something that no longer exists — fix the instruction, not
the check.

## Steps

1. **Generate the project** whenever `project.yml` changed or files were added to or
   removed from `Sources/`. XcodeGen builds the source list from the filesystem, so a new
   file will not be compiled until the project is regenerated:

   ```bash
   xcodegen generate
   ```

2. **Build.** A fixed `-derivedDataPath` gives a stable path to the `.app`, and a stable
   path helps TCC treat it as the same application across builds:

   ```bash
   xcodebuild -project Talkloom.xcodeproj -scheme Talkloom \
     -configuration Debug -derivedDataPath build build 2>&1 | xcsift -f toon -E
   ```

   The bundle lands at `build/Build/Products/Debug/Talkloom.app`.

   `xcsift` turns xcodebuild's output into a few lines of errors with file and line —
   measured at 98 kB against 127 bytes for a green test run. `-E` is not optional: a
   pipeline reports the exit status of its last command, so without it a failed build
   comes back as success. `-w` adds the list of warnings rather than just their count.

3. **Launch.** Kill the previous instance first — two simultaneous captures produce
   garbage in both recordings:

   ```bash
   pkill -f Talkloom.app/Contents/MacOS/Talkloom || true
   open build/Build/Products/Debug/Talkloom.app
   ```

4. **Watch the logs.** This is a menu-bar app with no console window, so this is the only
   way to see what it is doing:

   ```bash
   log stream --predicate 'subsystem == "me.diskin.Talkloom"' --level debug
   ```

   Start the stream *before* launching the app. Debug and info messages live in an
   in-memory ring buffer and are never written to the persistent store, so
   `log show --last 5m` will not find them after the fact — it only sees notice level
   and above. An empty `log show` therefore says nothing about whether the app logged.

   When backgrounding the stream from a shell, put the command in a script file: the
   nested quotes in the predicate do not survive zsh's parsing.

## Tests

The package first — it is a second, and it covers the WAV writer, the mach-time
conversion and the manifest:

```bash
swift test --package-path Packages/TalkloomCore
```

Then the app's own tests, which need the project, the bundle and its signature:

```bash
xcodebuild -project Talkloom.xcodeproj -scheme Talkloom \
  -derivedDataPath build test 2>&1 | xcsift -f toon -w -E
```

This is what `scripts/check.sh` runs, so prefer the script unless a single test is being
chased down.

When a parameterized Swift Testing case fails, `xcsift` names the test but not the
argument — it reports `header field, Test failed`. Re-run without the pipe to see which
row broke; the raw output names it.

### Sanitizer runs

Thread and address sanitizers over the hardware-free tests, both the package and the app:

```bash
scripts/sanitize.sh            # both, about 35 seconds
scripts/sanitize.sh thread     # or one of them
```

Run it after touching `AudioRingBuffer`, anything holding an `Unsafe*Pointer`, or actor
isolation on the capture path. The two sanitizers cannot be enabled together, so each is a
separate pass; the script does them in turn and prints the sanitizer's own summary, which
names the racing accesses, before the test verdict. Full output is kept at
`build-san/sanitize.log`.

Sanitizer builds use their own `-derivedDataPath`, so a run does not poison the ordinary
build cache and an ordinary build cannot satisfy a sanitizer run. Device tests are out of
scope on purpose: instrumentation slows the audio callback enough to manufacture dropouts.

A report does fail the run — verified against a deliberate race, which exits 65 with
`** TEST FAILED **`. Do not pipe this through `xcsift`; it discards the sanitizer summary,
which is the only part that says which access raced.

### Tests that use the real microphone

Capture code is only verified against a real recording, so those tests live in the
`TalkloomDeviceTests` scheme and are skipped by every other run:

```bash
xcodebuild -project Talkloom.xcodeproj -scheme TalkloomDeviceTests \
  -derivedDataPath build test \
  -only-testing:TalkloomTests/DeviceTests/Microphone
```

The suites are `Microphone`, `SystemAudio`, `Controller`, `StartupLatency`,
`VoiceProcessingLayout` and `Ducking`, and the `DeviceTests/` in the middle is not
optional: they are nested inside that suite so `.serialized` can keep two captures from
running at once. **An identifier that matches nothing runs zero tests and reports
success** — `-only-testing:TalkloomTests/Microphone` exits 0 having done nothing at
all. Check the count in the output (`Test run with N tests`) rather than the exit status.

Ducking is the slow one: nine four-second measurements of a 440 Hz tone, about a minute of
noise. Leave it out unless the ducking configuration is what is being checked.

They record from the microphone and speak out loud for a few seconds. They print the
measured rate, duration, peak amplitude and dropped-sample count for each track — those
numbers are what a capture commit has to carry.

**Do not pipe these through `xcsift`.** It reports pass and fail counts and discards the
tests' console output, which for a device test is the entire point: the measurements
would be summarised away and the commit would have no numbers to carry. Read the raw
output here, or `tee` it to a file.

A separate scheme rather than an environment variable on the command line: `xcodebuild`
does not forward the shell's environment to the test host, so `TALKLOOM_DEVICE_TESTS`
has to come from the scheme itself.

The output-device restart check is interactive and has a stronger cleanup requirement: a
test-host crash cannot run Swift `defer` blocks. Run it only after the user agrees to the
spoken switch protocol, through its parent-process harness:

```bash
scripts/device-switch-test.sh
```

The harness selects exactly one test and removes its recording, helper processes, probe
files, log and result bundle on success, assertion failure, signal, or test-host crash. Read
the raw measurements while it runs; they are deliberately not retained with private audio.

## When it doesn't work

Start with `scripts/doctor.sh` when the failure smells like the environment rather than
the code. It prints the toolchain, the selected developer directory, the SDK, the signing
identity and the Python tooling, and exits non-zero naming where anything missing comes
from. That is faster than inferring the cause from a build log, and it catches the first
two entries below outright.

- **`xcodebuild` missing, or complaining about the license** — only Command Line Tools are
  selected. Point at Xcode with
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, then
  `sudo xcodebuild -license accept`.
- **Signing error, identity not found** — the local certificate doesn't exist yet. Create
  it once with `scripts/make-signing-cert.sh` (it asks for the keychain password).
- **App launched but no menu-bar item appeared** — that is what a crash before item
  creation looks like; check the logs. `LSUIElement` hides the Dock icon, so a crash
  presents as "nothing happened".
- **App stopped asking for permission and records silence** — the signature or bundle id
  changed, so TCC considers it a different app. The skill `audio-doctor` has the reset and
  the rest of the empty-recording diagnosis.
- **A change had no effect** — almost always the file never made it into the project.
  Regenerate (step 1) and rebuild.

## What to report

The build result — success, or the specific errors with file and line — and, if the app
was launched, what the logs showed. Do not paste the full `xcodebuild` output. A successful
build is not evidence that a change works (`AGENTS.md`, "What counts as verified").
