---
description: Lint the research graph. Runs a deterministic integrity check over graph/ (dangling edges, invalid kinds/statuses, duplicate IDs, cycles, invalidation consistency) and offers to fix any violations.
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

If there is no `graph/` directory, the script says the repo isn't scaffolded; relay that and point
to `/tendrel:seed` rather than treating it as an error.
