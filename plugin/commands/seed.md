---
description: Seed the research graph — guided first-population of an empty graph/ from this project's current state. Proposes nodes for your approval before writing anything.
---

# Seed the research graph

Guide a first population of `graph/` for a project that has work but an empty (or nearly empty)
graph, following the **research-graph skill** (`skills/research-graph/SKILL.md`).

1. Read the project's existing artifacts (READMEs, plans, results, code structure) and ask the
   user to describe the current state where it isn't clear from files.
2. **Propose a node set first — do not write yet.** List proposed nodes as `id, kind, status,
   one-line summary, edges` for the user to correct: pipeline components as `pipeline_node`s with
   honest evidence statuses; in-flight work as `experiment`s; active theories with lifecycle
   stage and `next_gate`; locked methodological choices as `decision`s; plus the `depends_on` /
   `part_of` / `validates` edges between them.
3. Capture **current** state, not full history — one-line forward notes per node, not archaeology.
4. Only after the user approves, write the nodes as `graph/<ID>.md` files per the skill's format.

If `graph/` already has substantial content, don't duplicate — offer to reconcile/extend the
existing graph instead. If there is no `graph/` directory, point to `setup-research-repo.sh`.
