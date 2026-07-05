---
description: Regenerate status.md from graph/ — a one-screen view (theories by stage, pipeline nodes by evidence status, decisions, ideas) plus a mermaid diagram of the actual graph.
---

# Regenerate status.md

Generate `status.md` for this project from `graph/`, following the **research-graph skill**
(`skills/research-graph/SKILL.md`).

Include both parts the skill specifies:

1. **The graph visualization** — a `mermaid` flowchart of the actual nodes and edges, with
   node shapes/colors by kind and status (invalidated/blocked visually distinct from validated;
   theories showing their lifecycle stage) and the readability guard for large graphs.
2. **The text sections** — theories grouped by lifecycle stage with confidence and next gate;
   pipeline nodes grouped by evidence status; reversed decisions with reasons; open ideas.

Regenerate the file fresh from `graph/` each time; never hand-maintain it. If the graph is
empty, produce the text sections with no diagram. If there is no `graph/` directory, say the
repo isn't scaffolded rather than generating an empty file.
