---
description: Reconcile the research graph. Fold this session's work into graph/ (new/updated nodes, status transitions, edges) per the research-graph skill. On-demand, never automatic.
---

# Reconcile the research graph

Perform an on-demand reconcile of `graph/` for this project, following the **research-graph
skill** (`skills/research-graph/SKILL.md`) as the source of truth for how reconciliation works.

1. Compare what has happened since the last reconcile against the current `graph/`.
2. Create or update nodes, transition statuses, and add edges so the graph matches reality:
   experiments moving to `complete`/`abandoned` with results, pipeline nodes changing evidence
   status, new `depends_on`/`validates`/`invalidated_by` edges, ideas and observations captured.
3. If a `pipeline_node` became `invalidated`, trace downstream and report what is now affected.
4. Append any friction about the system to the tool-global friction log
   (`${CLAUDE_PLUGIN_DATA}/FRICTION.md`), tagged **confidently-wrong** vs **incomplete**.
5. Make only the reconcile edits, keep the summary terse, and return control to the user.

If this repo has no `graph/` directory, it is not scaffolded yet. Offer to scaffold it in-session
(create `graph/`, `raw/`, `wiki/`, and a `.research-graph` file with `project = <name>`), or point
to `/tendrel:seed`, rather than sending the user to a terminal. Do not create nodes until it is
scaffolded.

Reconcile is **not** backgrounded: run it inline whatever `background` is set to, because its input
is the live conversation, which a dispatched subagent cannot see. Honor `verbosity` for the
summary (`succinct` keeps it to a line or two).
