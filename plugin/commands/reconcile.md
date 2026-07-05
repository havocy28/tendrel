---
description: Reconcile the research graph — fold this session's work into graph/ (new/updated nodes, status transitions, edges) per the research-graph skill. On-demand; never automatic.
---

# Reconcile the research graph

Perform an on-demand reconcile of `graph/` for this project, following the **research-graph
skill** (`skills/research-graph/SKILL.md`) as the source of truth for how reconciliation works.

1. Compare what has happened since the last reconcile against the current `graph/`.
2. Create or update nodes, transition statuses, and add edges so the graph matches reality —
   experiments moving to `complete`/`abandoned` with results, pipeline nodes changing evidence
   status, new `depends_on`/`validates`/`invalidated_by` edges, ideas and observations captured.
3. If a `pipeline_node` became `invalidated`, trace downstream and report what is now affected.
4. Append any friction about the system to the tool-global friction log
   (`${CLAUDE_PLUGIN_DATA}/FRICTION.md`), tagged **confidently-wrong** vs **incomplete**.
5. Make only the reconcile edits, keep the summary terse, and return control to the user.

If this repo has no `graph/` directory, it is not scaffolded for tendrel — say so and point to
`setup-research-repo.sh` rather than creating nodes.
