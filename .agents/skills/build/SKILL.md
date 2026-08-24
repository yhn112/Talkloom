---
name: build
description: Build, sign, and launch Transcriber.app, run the tests, and read the app's logs. Use after code changes, when a change needs checking in the running app, and when the app won't launch or misbehaves. Do not use to diagnose recording quality — that is audio-doctor.
---

# Building, testing, and running

`.xcodeproj` is a generated artifact in this project. The source of truth is
`project.yml`, so the cycle always starts with generation, never with opening the project.

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
   xcodebuild -project Transcriber.xcodeproj -scheme Transcriber \
     -configuration Debug -derivedDataPath build build
   ```

   The bundle lands at `build/Build/Products/Debug/Transcriber.app`.

3. **Launch.** Kill the previous instance first — two simultaneous captures produce
   garbage in both recordings:

   ```bash
   pkill -f Transcriber.app/Contents/MacOS/Transcriber || true
   open build/Build/Products/Debug/Transcriber.app
   ```

4. **Watch the logs.** This is a menu-bar app with no console window, so this is the only
   way to see what it is doing:

   ```bash
   log stream --predicate 'subsystem == "me.diskin.Transcriber"' --level debug
   ```

   Start the stream *before* launching the app. Debug and info messages live in an
   in-memory ring buffer and are never written to the persistent store, so
   `log show --last 5m` will not find them after the fact — it only sees notice level
   and above. An empty `log show` therefore says nothing about whether the app logged.

   When backgrounding the stream from a shell, put the command in a script file: the
   nested quotes in the predicate do not survive zsh's parsing.

## Tests

```bash
xcodebuild -project Transcriber.xcodeproj -scheme Transcriber \
  -derivedDataPath build test
```

`xcodebuild` output is verbose. When diagnosing failures, search for `error:` and
`Test Case '-[...]' failed` rather than reading the whole log.

## When it doesn't work

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
  changed, so TCC considers it a different app. Reset and grant again:
  `tccutil reset Microphone me.diskin.Transcriber`, and the same for `AudioCapture`.
- **A change had no effect** — almost always the file never made it into the project.
  Regenerate (step 1) and rebuild.

## What to report

The build result — success, or the specific errors with file and line — and, if the app
was launched, what the logs showed. Do not paste the full `xcodebuild` output. Note that
a successful build does not demonstrate that a change works: anything touching audio is
only verified through a real recording.
