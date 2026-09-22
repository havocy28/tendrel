---
description: Lint the research graph. Runs a deterministic integrity check over graph/ (dangling edges, invalid kinds/statuses, duplicate IDs, cycles, invalidation consistency, provenance paths that don't resolve, mutual or self-referencing invalidated_by/supersedes/part_of edges, edge targets that do not resolve) and offers to fix any violations. Warns on a planned experiment with a config and no abandon_if, a complete experiment with validates and no compared_to, and a reopen_when naming a missing node or a status its node cannot hold. With --precheck, prints the stale-gate, exit, deferred, fired-trigger, and futility block that /tendrel:next quotes.
---

# Lint the research graph

Run the deterministic graph lint and report the result, following the **research-graph skill**
(`skills/research-graph/SKILL.md`), which owns the check list and the repair flow.

1. Run the bundled script against the current repo:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/graph-lint.sh"`. If `CLAUDE_PLUGIN_ROOT` is not set in this
   context, locate the tendrel plugin's `scripts/graph-lint.sh` in the plugin install directory and
   run it with the repo root as its argument. The script is read-only; it never writes to `graph/`.
2. Report its findings, honoring `verbosity` (succinct keeps it to a line or two).
3. On any **error**-severity violation (the script exits non-zero), summarize the errors and
   **offer** to fix them per the skill's "Graph lint" section. Apply fixes only after the user
   approves; never auto-fix. After an approved repair, **re-run the script** and report the result,
   so the deterministic check confirms the model-driven fix actually held.
4. When the user asks to explain the edges or see what each edge points at, run the script with
   `--explain` (optionally followed by node IDs after the repo path, to scope it) and relay the
   rendered lines, one per edge with its target's first line. This mode is read-only and offers no
   fix; it exists so an edge that resolves cleanly but points at the wrong node can be seen.
5. The hygiene warnings (a planned experiment with a `config` and no `abandon_if`; a complete
   experiment with a `validates` edge and no `compared_to`; a node-form `reopen_when` naming a
   node that does not exist, or a status that node's kind cannot hold) are warnings, never
   errors: relay them, offer nothing to fix unasked. `--precheck` (a leading flag, like
   `--explain`) prints the `PRECHECK:` block of stale gates, pending and crossed exits, deferred
   items, fired triggers, and futility that `/tendrel:next` quotes in its footer; it enumerates
   and never judges, and its findings become proposals at reconcile (the sweep runs it after its
   writes and reads the block whether or not the sweep caused a line), per the skill's "Graph
   lint" section.

If there is no `graph/` directory, the script says the repo isn't scaffolded; relay that and point
to `/tendrel:seed` rather than treating it as an error.
