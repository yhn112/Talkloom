# Process

Procedure, not invariants. `AGENTS.md` holds the rules that must be in context before
anything is touched; this file holds the steps that matter at the moment of acting, and is
read then.

Read before: running a hardware or diagnostic experiment, the first commit of a session,
and delegating to a subagent.

## The shape of a cycle

Keep each cycle small enough to review and interrupt safely:

1. State one question or hypothesis.
2. Make the smallest change that can answer it.
3. Run the narrow deterministic check.
4. Run a real-device or human-assisted check only when the question requires one.
5. Record the evidence and unresolved conditions.
6. Review a fixed diff, then checkpoint the logical change before beginning an unrelated
   experiment or refactor.

If the current task does not authorize commits, keep the parts as separate patches and
report the boundary explicitly. Keep verbose build and test output in a file; return the
status, the failing test, and only the relevant excerpt to the coordinating agent.

## Designing an experiment

Before a hardware-dependent or diagnostic run, state the hypothesis, controlled stimulus,
single variable, metric and time window, known confounders, and the result that would
settle the question. Change one unknown per run.

Asking the user for the run is covered by `AGENTS.md`; what belongs here is the shape of
the request. Give one reproducible protocol: what to play or say, how long, when to stay
silent, and what the recording will establish. Batch related phases into one protocol
instead of surprising the user with repeated device runs.

Keep three kinds of checks separate:

- deterministic regression tests belong in the normal test suite;
- hardware diagnostics and benchmarks belong in a separate diagnostic target or script;
- one-off probes belong in a temporary directory or an explicitly disposable branch.

## Git

### Branches

Work happens on topic branches named `<type>/<slug>` — kebab-case, English, e.g.
`feat/system-audio-tap`, `fix/tap-survives-device-change`. Types in use: `feat`, `fix`,
`refactor`, `docs`, `chore`. Branch before the first commit of a change, not after, and
delete the branch once it has been merged.

### Commits

Subject in the imperative, English, under 72 characters, no trailing period, prefixed
with the area touched — `capture`, `asr`, `ui`, `storage`, `build`, `docs`:

```
capture: preserve the timeline when the system tap restarts
```

One logical change per commit. Reformatting, renames, and behaviour changes go in
separate commits; mixed together they make the part that matters impossible to find later.

The body explains **why**, since the diff already shows what. For anything touching audio
capture or ASR, the body carries the measurement that verifies it — peak amplitude per
track, or WER per language. A capture change with no numbers is not reviewable, because
the failure mode it has to rule out is a valid file full of silence.

Commits written by an agent carry a `Co-Authored-By` trailer that identifies the agent.
It is there for transparency about who wrote what; drop this rule if it is unwanted.

### Before committing

- `scripts/check.sh` must pass.
- `git status` must show no generated artifacts. If one shows up despite `.gitignore`,
  fix `.gitignore` rather than working around it.
- Stage deliberately, and read what was picked up.
- No commented-out code and no debug logging left switched on.

### Rewriting history

Amend and rebase freely while a branch is local. Once it has been pushed or shared, do
not force-push it.

## Delegation

A delegation request names:

- the exact commit, base/head pair, or dirty-diff snapshot to examine;
- one independent question and the files or responsibility the agent owns;
- whether the task is read-only or which files it may edit;
- the evidence required for a conclusion and the checks the agent should run;
- the requested output, normally no more than the five highest-value findings.

Every finding uses the evidence categories in `AGENTS.md` and includes confidence. A
specialist must distinguish a reproduced defect from a code risk and a future design
issue. The coordinating agent verifies that evidence before changing priorities or
recording a P0.

A review verdict applies only to the named snapshot. The reviewer reports the revision or
diff it examined; any subsequent edit to the reviewed files invalidates the verdict and
requires a new review. Freeze those files while the final review is running.

Before relying on a delegated agent's findings, confirm it actually returned them.
Interrupting a turn also cancels the subagents that turn started, and the cancellation is
silent: no completion notification arrives and the agent's report is never written. Treat
"no result yet" as a state to check, never as evidence that work is still in progress.

## Changing a skill, a role, or an adapter

`scripts/check_docs.py` catches the mechanical failures — a stale version literal, a
missing role file, a command that no longer exists, a client's roster drifting out of sync
with `.agents/`. It does not establish that either client still discovers or runs the
thing.

So when the change touches discovery metadata, tool restrictions, or the pointer into
`.agents/`, verify it for both clients before calling the integration complete: discovery
from a fresh session, and one minimal invocation through each adapter. If a client cannot
be exercised locally, report that compatibility as unverified rather than inferring it
from matching file formats.
