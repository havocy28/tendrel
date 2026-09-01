---
description: Calibrate the research graph. Read-only measurement of whether the numbers in graph/ could be checked against the artifacts they cite (nodes asserting precise figures, declared provenance, match and coincidence rates). Writes nothing.
---

# Calibrate the research graph

Run the read-only calibration report and explain it, following the **research-graph skill**
(`skills/research-graph/SKILL.md`), whose "Calibrate" section owns what the figures mean.

1. Run the bundled script against the current repo:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/graph-calibrate.sh"`. If `CLAUDE_PLUGIN_ROOT` is not set in
   this context, locate the tendrel plugin's `scripts/graph-calibrate.sh` in the plugin install
   directory and run it with the repo root as its argument. The script is read-only; it writes
   nothing, anywhere.
2. Relay the report honoring `verbosity`. Under `succinct`, give the four headline figures only,
   read from these exact lines:
   - nodes asserting precise numbers: section 1, the `claim-bearing nodes, whole-node rule` line;
   - nodes declaring provenance: section 3, the `nodes declaring provenance: paths` line;
   - numbers checkable against their artifacts: section 4, the `wide (+ body paths)` row with
     `scripts searched`. It prints `unmatched N/M`; report it as "N of M numbers not found in their
     cited artifacts" (or 100 minus the percentage, as a found rate), never as a found count;
   - coincidence: section 10, the `combined coincidental pass rate` line, plus the `2dp` row,
     which is the rate for two-decimal figures.
   Under `normal`, add one plain-language sentence per figure on what it means for this graph.
3. Offer nothing to fix. A low provenance count is an invitation to declare `provenance:` as nodes
   are next touched, not an error; `/tendrel:lint` is where declared paths get checked.
4. If the user asks whether tendrel should check the numbers themselves on this graph: a
   coincidental pass rate in the tens of percent means a matching check would pass for the wrong
   reasons, and say so plainly. A rate near zero on a graph with many declared artifacts is worth
   noting in the friction log, since it is the evidence that check would need.

If there is no `graph/` directory, the script says the repo isn't scaffolded; relay that and point
to `/tendrel:seed` rather than treating it as an error.
