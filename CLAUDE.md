@AGENTS.md

The imported `AGENTS.md` is the authoritative project instruction file.

Reusable skills are exposed to Claude Code through `.claude/skills`, which points to the
canonical `.agents/skills` directory. Native Claude Code subagent definitions live in
`.claude/agents`; each one delegates its durable role instructions to `.agents/roles`.

Do not duplicate project rules, skill instructions, or role instructions here. Update
their canonical files instead.
