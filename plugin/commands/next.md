---
description: Plan forward from the graph's history. Reads the whole graph and returns a human-readable state-of-the-investigation brief plus 2-3 grounded next-experiment proposals (each with why-now and what-to-skip). Read-only; writes nothing. Node IDs stay in a skippable trace footer, never the body.
---

# What should we run next?

Synthesize `graph/` into a forward plan for this project, following the **research-graph skill**
(`skills/research-graph/SKILL.md`), specifically its "Planning forward (next)" section, which is
the source of truth for how this works.

1. **Lint first.** Run the bundled `graph-lint.sh` against the current repo
   (`bash "${CLAUDE_PLUGIN_ROOT}/scripts/graph-lint.sh"`; if `CLAUDE_PLUGIN_ROOT` is not set in this
   context, locate the tendrel plugin's `scripts/graph-lint.sh` in the plugin install directory and
   run it with the repo root as its argument). On error-severity violations, summarize them and
   offer repair before trusting a plan; warnings do not block. The lint is read-only.
2. **Read the whole graph** and produce, in order: a **human-readable brief** (the investigation
   arc, what is validated and what it rests on, what was ruled out, open theories and their gates,
   ideas never pursued) and **2-3 proposals**, each with why-now and what-to-skip-and-why.
3. **No node IDs in the brief or proposals.** Name things in plain language. End with a single,
   skippable "Where this came from" trace footer as the only place IDs appear, citing only nodes
   that exist. Honor `verbosity` for how much of the brief surfaces.

This is read-only: it proposes next steps and never writes to `graph/`.

If there is no `graph/` directory, or it exists but has no nodes yet, the repo isn't scaffolded for
planning: offer to scaffold it in-session (or point to `/tendrel:seed`) rather than planning from an
empty graph, there is no history to synthesize.
