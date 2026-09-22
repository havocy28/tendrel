---
description: Plan forward from the graph's history. Reads the whole graph and returns a human-readable state-of-the-investigation brief that ends in one verdict (continue, conclude, or wait), with 2-3 grounded next-experiment proposals when the verdict is continue (each with why-now, what-to-skip, and the losing outcome that would end it). Read-only; writes nothing. Node IDs stay in a skippable trace footer, never the body.
---

# What should we run next?

Synthesize `graph/` into a forward plan for this project, following the **research-graph skill**
(`skills/research-graph/SKILL.md`), specifically its "Planning forward (next)" section, which is
the source of truth for how this works.

1. **Lint first, with the pre-check.** Run the bundled `graph-lint.sh` against the current repo
   (`bash "${CLAUDE_PLUGIN_ROOT}/scripts/graph-lint.sh" --precheck .` from the repo root; if
   `CLAUDE_PLUGIN_ROOT` is not set in this context, locate the tendrel plugin's
   `scripts/graph-lint.sh` in the plugin install directory; the flag comes first, the repo root
   after it). The `PRECHECK:` block lists stale gates, pending and crossed exits, deferred items,
   fired triggers, and futility, or says `precheck: silent`. On error-severity violations,
   summarize them and offer repair before trusting a plan; warnings do not block. The lint is
   read-only.
2. **Read the whole graph** and produce, in order: a **human-readable brief** (the investigation
   arc, what is validated and what it rests on, what was ruled out, open theories and their gates,
   ideas never pursued, the pre-check's findings in plain language) and then **the verdict**.
3. **One verdict, on one body line.** `Verdict: continue` keeps the 2-3 proposals, each with
   why-now, what-to-skip-and-why, and the losing outcome that would end its line. `Verdict:
   conclude` states what stands, what it rests on, and what would reopen it. `Verdict: wait` names
   what unlocks the work, listing every trigger. A pre-check `FUTILITY` line forces wait; a graph
   with nothing open or deferred is never wait; otherwise judge under the skill's burden of proof.
   Deferred items are listed under "Waiting on" and never proposed without a fired trigger.
4. **No node IDs in the brief or proposals.** Name things in plain language. End with a single,
   skippable "Where this came from" trace footer as the only place IDs appear, citing only nodes
   that exist. The footer carries `Pre-check:` with the block quoted verbatim and `Verdict rests
   on:` with the node IDs behind the verdict. Honor `verbosity` for how much of the brief
   surfaces; the `Verdict:` line and the footer always survive.

This is read-only: it proposes next steps and never writes to `graph/`, under every `reconcile`
value. A stale gate, a crossed exit, or a fired trigger becomes a proposal at reconcile, not a
change here.

If there is no `graph/` directory, or it exists but has no nodes yet, the repo isn't scaffolded for
planning: offer to scaffold it in-session (or point to `/tendrel:seed`) rather than planning from an
empty graph, there is no history to synthesize.
