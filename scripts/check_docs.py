#!/usr/bin/env python3
"""Checks that the project's instructions and metadata still describe the project.

Agent-facing documentation fails silently. A role that names a deleted script, an adapter
pointing at a role that was renamed, or a version literal left behind by a change that
moved the floor all read as authoritative and are wrong. `a1e9e68` raised the deployment
target to macOS 15 and updated `project.yml`, `PLAN.md` and `docs/system-audio-capture.md`
while leaving the old floor in `api-scout` and `check-api` — the two files whose entire job
is checking availability. Nothing caught it, because nothing was looking.

This enforces the mechanical half of "one fact, one place" in `AGENTS.md`: build metadata
is referenced from its owning build setting, version literals are not duplicated in the
rules files, paths do not dangle, the two clients expose the same roles, every document is
reachable from the reading list, and the rules file stays inside its size budget. It cannot
check whether prose is still true; that stays a human job.

Standard library only, and run with the system interpreter — `scripts/check.sh` calls it
before anything is built, so it must not depend on `.venv`.
"""

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Paths named in the instructions for work that is planned but not yet built. Anything
# here is a promise, not a mistake; delete the entry when the path appears.
PLANNED = {
    "tests/fixtures/",
    "tests/reports/",
    "tests/reports/baseline.md",
    "Recordings/",
}

problems: list[str] = []


def fail(path: Path, line: int, message: str) -> None:
    problems.append(f"{path.relative_to(ROOT)}:{line}  {message}")


def numbered(path: Path):
    return enumerate(path.read_text().splitlines(), start=1)


def line_containing(path: Path, needle: str) -> int:
    return next((line for line, text in numbered(path) if needle in text), 1)


def docs() -> list[Path]:
    return [
        ROOT / "AGENTS.md",
        ROOT / "CLAUDE.md",
        ROOT / "PLAN.md",
        *sorted((ROOT / "docs").glob("*.md")),
        *sorted((ROOT / ".agents").rglob("*.md")),
        *sorted((ROOT / ".claude" / "agents").glob("*.md")),
        *sorted((ROOT / ".codex" / "agents").glob("*.toml")),
    ]


# 1. Version literals belong to project.yml. A rule, a role or a skill that repeats one is a
# copy that will not be updated when the floor moves. Documents under docs/ are exempt: they
# cite SDK availability, which is a fact about macOS rather than a copy of our own setting.
VERSION = re.compile(r"\bmacOS\s+\d+(?:\.\d+)*")

for path in [ROOT / "AGENTS.md", *sorted((ROOT / ".agents").rglob("*.md"))]:
    for line, text in numbered(path):
        for hit in VERSION.finditer(text):
            fail(path, line, f"version literal {hit.group(0)!r} — read it from project.yml")

# 2. Info.plist references the build settings that own identity, version and deployment
# metadata. Literals here are silent copies: Xcode accepts them even after project.yml has
# changed, so the built bundle can disagree with its source of truth.
info_plist_path = ROOT / "Resources" / "Info.plist"
with info_plist_path.open("rb") as file:
    info_plist = plistlib.load(file)

metadata_settings = {
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
}
for key, expected in metadata_settings.items():
    actual = info_plist.get(key)
    if actual != expected:
        fail(
            info_plist_path,
            line_containing(info_plist_path, f"<key>{key}</key>"),
            f"{key} is {actual!r}; reference build setting {expected!r}",
        )

# 3. The bundle identifier may appear in a command an agent copies, but it has to be the
# real one: a stale id resets the wrong TCC grant and the recording stays silent.
project = (ROOT / "project.yml").read_text()
bundle_id = re.search(r"PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)", project)
if not bundle_id:
    problems.append("project.yml  PRODUCT_BUNDLE_IDENTIFIER not found")
else:
    expected = bundle_id.group(1)
    other = re.compile(r"\bme\.diskin\.[A-Za-z0-9_.]+")
    for path in docs():
        for line, text in numbered(path):
            for hit in other.finditer(text):
                if hit.group(0) != expected:
                    fail(path, line, f"bundle id {hit.group(0)!r} != project.yml {expected!r}")

# 4. Every repository path named in backticks exists. This is what catches a renamed
# script, a moved document, and a role that was consolidated away.
ROOTS = ("scripts/", "docs/", ".agents/", ".claude/", ".codex/", ".github/", "Packages/", "Sources/", "Tests/", "tests/", "Recordings/")
PATHLIKE = re.compile(r"`([^`\s]+)`")

for path in docs():
    for line, text in numbered(path):
        for hit in PATHLIKE.finditer(text):
            ref = hit.group(1)
            if "<" in ref or "*" in ref or ref in PLANNED:
                continue
            if not (ref.startswith(ROOTS) or re.fullmatch(r"[A-Z][A-Za-z]*\.md|project\.yml", ref)):
                continue
            if not (ROOT / ref).exists():
                fail(path, line, f"names {ref!r}, which does not exist")

# 5. The two clients must offer the same roles, and every adapter must point at a role
# that is really there. A half-renamed role is invisible until a session cannot find it.
roles = {p.stem for p in (ROOT / ".agents" / "roles").glob("*.md")}
claude = {p.stem for p in (ROOT / ".claude" / "agents").glob("*.md")}
codex = {p.stem for p in (ROOT / ".codex" / "agents").glob("*.toml")}

for name, have in (("(.claude/agents)", claude), ("(.codex/agents)", codex)):
    if have != roles:
        missing = sorted(roles - have)
        extra = sorted(have - roles)
        problems.append(
            f".agents/roles {name} roster differs — missing {missing}, unexpected {extra}"
        )

# 6. An adapter that does not name its role has silently stopped delegating, and the
# subagent runs on discovery metadata alone.
for path in [*(ROOT / ".claude" / "agents").glob("*.md"), *(ROOT / ".codex" / "agents").glob("*.toml")]:
    if f".agents/roles/{path.stem}.md" not in path.read_text():
        problems.append(f"{path.relative_to(ROOT)}  does not point at .agents/roles/{path.stem}.md")

# 7. A skill is found by the name in its frontmatter; a directory that disagrees with it
# is a skill that cannot be invoked by the name the documentation uses.
for skill in sorted((ROOT / ".agents" / "skills").glob("*/SKILL.md")):
    declared = re.search(r"^name:\s*(\S+)", skill.read_text(), re.MULTILINE)
    if not declared:
        problems.append(f"{skill.relative_to(ROOT)}  frontmatter has no name")
    elif declared.group(1) != skill.parent.name:
        problems.append(
            f"{skill.relative_to(ROOT)}  declares {declared.group(1)!r}, directory is {skill.parent.name!r}"
        )

# 8. The roster in AGENTS.md is what an agent reads when choosing whom to delegate to.
agents_md = (ROOT / "AGENTS.md").read_text()
listed = set(re.findall(r"^- `([a-z-]+)` — ", agents_md, re.MULTILINE))
if listed != roles:
    problems.append(
        f"AGENTS.md  delegation roster {sorted(listed)} != .agents/roles {sorted(roles)}"
    )

# 9. Every document must be reachable from the reading list in AGENTS.md. A document nobody
# is told to read goes stale unobserved and is re-derived by the next agent who needs it:
# docs/asr-evaluation.md owned the reference-transcript policy while being absent from that
# list, so the one document that says which numbers may be quoted was the one nobody was
# routed to.
reading_list = agents_md.split("## What to read, and when", 1)
if len(reading_list) == 1:
    problems.append("AGENTS.md  the 'What to read, and when' section is gone")
else:
    routed = set(re.findall(r"`(docs/[^`\s]+\.md)`", reading_list[1].split("\n## ", 1)[0]))
    for document in sorted((ROOT / "docs").glob("*.md")):
        reference = f"docs/{document.name}"
        if reference not in routed:
            problems.append(f"AGENTS.md  the reading list does not name {reference}")

# 10. AGENTS.md is read in full before anything is touched, and Codex stops loading project
# documents once they reach project_doc_max_bytes — 32 KiB by default — so every byte here is
# spent out of each session's attention and out of the other documents' shelf space. This is
# not a style preference. The file was cut for size once (`df15663`, 401 lines to 370) and was
# back to 407 seven commits later, every addition individually defensible. The budget is what
# makes a new rule displace an old one, or a measurement move to docs/ where it belonged.
AGENTS_BUDGET = 23 * 1024
agents_size = (ROOT / "AGENTS.md").stat().st_size
if agents_size > AGENTS_BUDGET:
    problems.append(
        f"AGENTS.md  {agents_size} bytes over a budget of {AGENTS_BUDGET} — move a measurement "
        "into docs/ or delete a rule; raising the number is a decision to argue in the commit"
    )

if problems:
    print("\n".join(problems), file=sys.stderr)
    sys.exit(1)
