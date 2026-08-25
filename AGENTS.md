# Transcriber

A local meeting transcriber for macOS: a menu-bar app records the microphone and system
audio during a call, transcribes locally with Whisper, and produces a summary. Meetings
are held in Russian and English. Full scope and staging live in `PLAN.md`.

Everything in this repository is written in English — documentation, comments, script
output, commit messages, UI strings. Conversation with the user happens in Russian; that
is about the chat, and never about what goes into a file.

## What to read, and when

This file is the only one that has to be read in full before touching anything: it is the
rules. The rest are looked up when the task calls for them. Session notes, scratch logs and
transcripts of previous work are not project documentation and do not belong in the
repository; if something learned that way is durable, it goes into one of these files in
the same change.

- `PLAN.md` — product scope and the staging. Read before deciding *what* to build next, or
  when a change seems to belong to a later stage.
- `docs/process.md` — how to run a cycle, design an experiment, write a commit, and brief
  a subagent. Read before the first commit of a session, before a hardware run, and
  before delegating.
- `docs/technical-debt.md` — known design and correctness debt, prioritised. Read before
  starting cleanup work, and add to it when leaving something unfinished.
- `docs/system-audio-capture.md` — process taps and aggregate devices, every claim cited to
  an SDK header and line. Read before touching the system-audio path.
- `docs/speech-framework.md` — why Apple's `Speech` module is not used, and what it does and
  does not provide. Read before proposing it for recognition or for endpointing.
- `.agents/skills/*/SKILL.md` — how to build, record, diagnose a recording, measure ASR.
  Read the one that matches the task at hand.
- `.agents/roles/*.md` — what each delegated subagent is responsible for.

## Environment

macOS on Apple silicon, Xcode, and the tools in `Brewfile`. Setup is `brew bundle`,
`uv sync`, then `scripts/make-signing-cert.sh` once. `scripts/doctor.sh` prints what this
machine actually has and names where anything missing comes from — ask it rather than
trusting a version written down anywhere.

What asking the machine cannot tell you:

- **`.xcodeproj` is a generated artifact, not a source of truth.** It comes from
  `project.yml` via XcodeGen; edit that and regenerate. Never hand-edit it, never commit it.
- The signing certificate is local and self-signed so that TCC grants survive a rebuild.
  Ad-hoc signatures do not.
- `swift-format` comes from `xcrun`, not Homebrew: a second copy is a second opinion.
- `.venv` is evaluation tooling only. Nothing in it ships; the app is Swift throughout.

## Rules

### This file is where the project's rules live

Durable rules, conventions, and decisions belong in the repository — here, in `PLAN.md`,
or in the shared skill and role definitions under `.agents/`. Do not keep them in agent memory
outside the project: rules stored there are invisible to the user, cannot be reviewed in
a diff, and drift out of sync with the code they govern.

When the user establishes a new rule, write it into the appropriate file in this
repository as part of the same change.

### One fact, one place

Every fact, number, command, and version lives in exactly one file. Other files name it
and point there; they do not restate it. A repeated threshold or version is a defect, not
redundancy: it gets updated in one place and not the other, and the stale copy is
invisible in the diff that caused the drift. `a1e9e68` moved the deployment floor and left
the old one standing in the two files whose job is checking availability.

Who owns what:

- `PLAN.md` — product stages and the criterion that ends each. Not work items.
- `AGENTS.md` — enforceable repository and implementation rules.
- `docs/technical-debt.md` — outstanding work, one identified item each.
- `docs/` otherwise — measurements, API research, decisions, procedure.
- roles and skills — how to perform or verify work, never restating the architecture.
- source comments — only the local invariant needed to read that code.

So versions, bundle identifiers and thresholds are absent from `.agents/` entirely; roles
and skills read them from `project.yml`. A role states scope, judgement and what to report,
while the procedure lives in the skill it names. "What to do next" is read as the current
stage plus its open P0s, never kept as a third list.
`scripts/check_docs.py` enforces the mechanical half, inside `scripts/check.sh`.

Technical-debt records are living handoffs, not a historical notebook. Each item names
its status, evidence, exit criterion, and the commit that introduced or resolved it when
known. A change that resolves or invalidates an item updates the debt record in the same
logical change. Before prioritizing an old P0, reconcile it against the current code and
reproduce it; stale severity is not evidence.

### Design for this project, not by analogy with other repositories

Do not go looking through other repositories on this machine for conventions to copy.
Those projects solved different problems; their structure is noise here. Decisions come
from this project's requirements and from verified facts about this environment. Read
another repository only when the user points at it explicitly.

The user has explicitly approved `tobi/recorder` as an upstream implementation to consult
before designing overlapping work. Its reviewed components, compatibility boundaries and
reuse procedure live in `docs/upstream-recorder.md`. Use that map to avoid repeating its
design exploration, but do not treat another application's observations as SDK guarantees
or let its different product choices override this project's invariants.

### Work in short, evidence-driven cycles

Before implementing a non-trivial change, write down the decision that makes the change
necessary. At minimum, establish:

- whether the behavior is needed live or can happen after recording;
- which artifact is the source of truth and which artifacts are derived;
- whether macOS or an existing project dependency already provides the operation;
- whether a product choice, permission, dependency, or hardware requirement needs the
  user's decision before the architecture is chosen.

Do not build a project-specific subsystem before checking the platform tool that would
replace it, and do not continue through a consequential ambiguity just because one option
is technically implementable. For unfamiliar behavior the order is: project invariants, SDK
headers, first-party documentation, the smallest controlled experiment, then production
code. An experiment tests a stated hypothesis; it does not decide what the product needs.

Do not combine a verified change and a partially applied experiment in one dirty diff. The
shape of a cycle is in `docs/process.md`.

### Separate facts, measurements, and hypotheses

Use these words precisely in investigations, reviews, and handoffs:

- **Confirmed fact** — guaranteed by a cited SDK header or project invariant.
- **Reproduced behavior** — observed in a named test or recording, with numbers.
- **Code risk** — a path that can plausibly fail but has not been reproduced.
- **Future concern** — relevant to a later stage, not a defect in current scope.

Never report a code risk or future concern as a confirmed defect. P0 is a reproduced
failure, a violated invariant, or a path that demonstrably loses user data. State
confidence and what remains unverified.

Name the layer that owns a behavior — macOS, this project's code, or the harness — and do
not turn a measurement from one layer into a guarantee about another. In particular,
capture levels do not establish what Whisper will recognize; only an ASR evaluation does.

### A hardware run needs the user's consent, and cleans up after itself

If a run uses the microphone, speakers, TCC prompts, or a person in the room, tell the
user before launching it and ask. Never surprise them with a device run.

Every hardware harness must clean up spawned processes, CoreAudio objects, recordings,
and result bundles on success, failure, timeout, and interruption. It must be safe to run
twice after a failed attempt.

How to design the run, and where each kind of check belongs, are in `docs/process.md`.

### Missing a tool? Ask — don't route around it

If a task needs a tool that isn't installed, say so and ask, rather than quietly
building a workaround. A workaround chosen on the user's behalf becomes the project's
permanent platform, and nobody revisits it afterwards.

Distinguish two cases. Something that costs the user a real decision — Xcode, a paid
API, a developer certificate, hardware — is a question. An ordinary library or CLI tool
is not: install it yourself (`brew`, `uv pip install` into `.venv`, a SwiftPM
dependency) and say that you did.

### Unfamiliar system API: read the headers before writing code

CoreAudio process taps, ScreenCaptureKit, and Voice Processing IO have very few public
examples. Their signatures and constants are unusually easy to invent, and the mistake
does not surface at compile time — it surfaces as silence in the recording.

Before using an unfamiliar symbol, find it in the SDK headers and read the docs there
(skill `check-api`). Never write CoreAudio code from memory. Check availability against
the `API_AVAILABLE` attribute in the header, not against intuition.

### Real-time safety in audio callbacks

Inside `AudioDeviceIOProc`, `AVAudioNodeTapBlock`, and `SCStreamOutput`, anything that
can block or run for an unbounded time is forbidden: allocation, locks, file I/O,
`print`, `async`/`await`, Foundation collections, and ARC traffic on objects whose
lifetime isn't guaranteed.

A callback only copies samples into a preallocated lock-free ring buffer. Disk writes,
VAD, and ASR belong to a separate thread or actor that drains the buffer; resampling does
not belong to either, and happens offline once the file is finished — see below.
Violating this produces clicks and dropouts that take hours to track down later.

### Audio format and separate tracks

Capture writes the device's own format, untouched — mono Int16 PCM at whatever sample rate
the device reports. That file is the master. The canonical ASR format, 16 kHz mono Int16 on
disk and Float32 in `[-1, 1]` in memory for Whisper, is **derived from the master
afterwards**, over the finished file, with `afconvert`.

**Never resample on the audio path.** A resampler is a polyphase FIR holding some 30 input
frames in its delay line, and it only releases them when the stream is declared finished. A
drain loop can never declare that — more audio is always coming — so it abandons the
filter's contents on every pass, and any pass that hands the converter more input than one
call consumes loses the remainder outright, reporting success either way. Measured on a
one-second 48 kHz tone through a 50 ms drain loop: 6% of the recording gone. The same
conversion over a finished file is frame-exact at every rate a device might report. Nothing
in this project needs live audio — transcription happens after the meeting.

`afconvert` rather than `ffmpeg` for anything the app itself runs: it ships with macOS, so
the app does not acquire a Homebrew dependency it cannot satisfy on someone else's machine.
`ffmpeg` stays available for the Python evaluation tooling, which only ever runs here.

Keeping the master also means a better model can be re-run later against the original audio
instead of against a downsampled copy.

**Microphone and system audio are written to two separate files and never mixed.** This
is the foundation of diarization, not an implementation detail: the split already gives
an exact "me" vs "everyone else" for free. Any proposal to fold them into one file is a
product regression, not an optimization.

Echo cancellation is data-destructive and may start only after the running process tap
has recorded a known active verification signal. Creating or starting the tap is not
evidence of health. If verification fails, keep the system path running but record the
microphone without echo cancellation, mark it as mixed, and warn that the session is
degraded; that preserves both sides through the speakers instead of erasing the remote
side from every usable track. The probe and the evidence behind this policy are described
in `docs/system-audio-capture.md`.

Both tracks must share a common time origin so segments can be merged by timestamp.
Capture each stream's start time explicitly instead of assuming the two streams start
together — they do not. The process tap delivers its first sample almost immediately;
the microphone's echo canceller takes about 0.75 s to come up, and some 2.7 s the first
time in a process. That gap is accepted rather than hidden: the meeting's opening seconds
exist only on the system side. Removing it would mean holding the microphone open before
the user asks to record, and a transcriber that lights the microphone indicator while
idle is not a trade this project makes.

Each track's first-sample timestamp is written to `session.json` beside the audio, so a
recording explains its own timeline to whatever reads it next.

### An ASR engine's timestamps are an estimate; the chunk's bounds are a measurement

The offset and duration of a chunk come from this project's own recording. What an engine
returns inside them is the model's guess at where the words fell, produced from tokenized
audio by something that infers time rather than measuring it.

So a returned timestamp outside the chunk is a bad estimate, never evidence that the words
are wrong, and **a transcript must never be discarded because of one**. Fold the estimate
into the measured bounds and keep the text, counting the repairs so a run with untrustworthy
timing is visible rather than silently smoothed over. Rejecting a whole response belongs to
responses that cannot be parsed at all.

The corollary is about prompts: never state a bound the audio does not have. A model told the
chunk is longer than it is will place words in audio that does not exist, and the error is
this project's, not the provider's.

### Swift 6

Strict concurrency is on (`SWIFT_STRICT_CONCURRENCY = complete`); do not silence
compiler warnings. UI is `@MainActor`, capture runs on a dedicated actor or thread, ASR
on its own actor. `@unchecked Sendable` is an exceptional escape hatch, not a way to
silence the compiler: every use needs an adjacent comment that states the synchronization
or lifetime invariant which makes it safe, and a final read-only `swift-reviewer` review.

`SWIFT_VERSION` is the language mode, and `6.0` already means mode 6; there is no `6.2`
mode to move to. Compiler features from later releases — `@concurrent`,
`nonisolated(nonsending)` — come with the toolchain and are available now.

Default `MainActor` isolation (`-default-isolation MainActor`, Swift 6.2) is deliberately
**not** enabled. It suits an app whose types are mostly UI; here most types exist
specifically to be off the main actor — the ring buffer, the track input, the recorders —
and the setting would turn every one of them into an annotation exercise.

Locks and atomics come from `Synchronization` in the standard library. The floor is
macOS 15.0 exactly so that they can.

### Where code goes

Two places, and the line between them is testability, not tidiness.

`Packages/TranscriberCore` holds what can be verified without hardware: the WAV writer,
the mach-time conversion, session and transcript models, and cloud clients behind a fakeable
transport. Its tests run with
`swift test --package-path Packages/TranscriberCore` in about a second — no xcodebuild, no
signing, no test host — so anything that can live there should.

The app target holds everything that touches CoreAudio, AVFoundation, TCC or the UI, and
the ring buffer with it: an audio callback calls `AudioRingBuffer.write` directly, Swift
does not inline across module boundaries by default, and the real-time path is not where a
module boundary should be paid for.

The dependency only points one way. `TranscriberCore` must not learn what a
`TrackRecorder` is; the app translates at the seam (`TrackReport`).

### Tests

Tests are Swift Testing — `@Suite`, `@Test`, `#expect`, `#require`. There is no XCTest
left in the project; add some only for what Swift Testing cannot express, which here means
`measure` blocks and UI automation, and say why in the file.

Prefer a table to a repeated test. Header fields, memory layouts, legacy manifest shapes:
one `@Test(arguments:)` where every row is a named case beats a dozen assertions in one
test whose failure names only the test. `WAVWriterTests` is the example to copy. A test
whose assertion is about the whole table — the ducking ranking — stays one test.

Sanitizers are a separate, rare run: `scripts/sanitize.sh`, about half a minute. Required
before calling done a change to the ring buffer, to anything holding an `Unsafe*Pointer`,
or to actor isolation on the capture path — a green `scripts/check.sh` says nothing at all
about a data race. Deliberately not part of that gate; the skill `build` has the procedure.

Anything touching audio hardware belongs under the `DeviceTests` suite, whatever file it
lives in. That suite is `.serialized`, and it has to be: Swift Testing runs tests in
parallel by default, while the microphone, the process tap and the default output device
are exclusive. It also carries the opt-in condition and a time limit, so no suite repeats
either.

### Permissions (TCC)

Three distinct permissions that are easy to confuse:

- microphone — `kTCCServiceMicrophone`, key `NSMicrophoneUsageDescription`;
- system audio via process tap — `kTCCServiceAudioCapture`;
- ScreenCaptureKit — `kTCCServiceScreenCapture`. The app does not use it: requesting the
  heavyweight Screen Recording permission for audio-only capture is not an acceptable
  fallback.

TCC binds a grant to the bundle's signature, so a changed certificate or bundle id
silently invalidates it and the next recording is empty. The skill `audio-doctor` has the
reset.

### Privacy

Recordings, transcripts, and summaries stay on the machine. Sending audio or text to an
external API happens only when the user explicitly enables it, and the UI must show that
it is on. Do not add telemetry, analytics, or "anonymous crash reporting".

The one pre-UI testing exception for credentials is the non-shipping ASR evaluator: it may
read `.openrouter.apikey` from the repository root only after confirming that Git ignores
the file. Transcriber.app never reads that file, and no credential may be staged or committed.

### Never commit

`Transcriber.xcodeproj` (generated), models (`*.bin`, `*.mlmodelc`, `*.gguf`),
recordings (`*.wav`, `*.caf`, `*.m4a`), transcripts, `build/`, `.venv/`, API keys.

## Git

`main` always builds and stays signable. Never leave it in a state where `xcodebuild`
fails. Work happens on topic branches named `<type>/<slug>`; branch before the first
commit of a change, not after.

Before committing, `scripts/check.sh` must pass, and staging is deliberate: never
`git add -A` without reading what it picked up — recordings and API keys are exactly what
leaks that way.

Branch and commit conventions, what belongs in one commit, and the rules for rewriting
history are in `docs/process.md`. Read it before the first commit of a session.

## What counts as verified

`scripts/check.sh` is the gate for everything that does not need hardware: it regenerates
the project, checks the instructions for drift, checks that the Python tooling starts,
checks formatting, builds, and runs the hardware-free tests, and it exits non-zero on the
first failure. Run it before saying a change is done. It takes about six
seconds, so there is no reason to skip it.

A green run there is not working capture. It is compatible with this project's signature
failure: a valid `.wav` of exactly the right duration containing pure silence. Capture code
is therefore not verified until it has been checked against a real recording — record a few
seconds and inspect duration and **peak amplitude of both tracks** (skill `audio-doctor`).

An ASR change is not an improvement without a measurement on both the Russian and
English fixtures (skill `asr-eval`). "Sounds better" is not a result.

### Ask the user to make the sound

`say` and `afplay` are enough to prove that a track is not silent, and not much more. They
cannot produce a real voice in a real room, a real call with a real remote party, or the
device changes that happen mid-meeting. The user is at the machine and has offered to
play audio, speak into the microphone, and take part in comparisons — so ask, rather than
extending a synthetic harness until it almost answers the question.

Ask for something specific and reproducible: what to play, what to say, how long, and what
the recording is meant to settle. Then analyse the files and report numbers.

Synthetic audio still has its place: a constant tone of known amplitude is what makes an
absolute level measurable at all, and it is what caught the resampler loss described above.
Use it for arithmetic, and a person for anything that has to sound like a meeting.

## Skills and delegation

Reusable project skills have one source of truth under `.agents/skills/`; subagent role
instructions have one under `.agents/roles/`. Codex discovers those directories directly,
Claude Code reaches the skills through the `.claude/skills` symlink, and the files in
`.claude/agents/` and `.codex/agents/` are client-specific adapters holding only discovery
metadata, tool or sandbox restrictions, and a pointer to the shared role. Add and edit
skills and roles only under `.agents/`; never maintain a second client-specific copy.

- `api-scout` — confirm a system API's signature, availability, and semantics before code is written.
- `audio-capture` — implement and debug the audio capture layer.
- `swift-reviewer` — review concurrency and real-time safety before calling a task done.
- `asr-quality` — model selection, hallucination control, Russian/English quality.

Delegate a bounded specialist task when one of these roles matches. The main agent owns
coordination, waits for delegated work, and integrates the result. Do not send two
write-capable agents into overlapping files at the same time, and do not ask multiple
agents for broad audits of the same subsystem. Keep small, tightly coupled tasks in the
main agent when delegation would add coordination without independent work.

For an audio-capture or concurrency change, delegate the final read-only review to
`swift-reviewer` before declaring the work complete. For an unfamiliar macOS system API,
delegate verification to `api-scout` before implementation.

How to brief a specialist, what it owes in return, and how a review verdict is scoped are
in `docs/process.md`.
