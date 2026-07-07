---
description: Seed the research graph. Guided first-population of graph/ from this project's current state, scaffolding the repo in-session first if needed. Proposes nodes for your approval before writing.
---

# Seed the research graph

Guide a first population of `graph/` for a project, following the **research-graph skill**
(`skills/research-graph/SKILL.md`).

**If the repo is not scaffolded yet** (no `graph/` directory), scaffold it in-session first. Do
not send the user to a terminal or a shell script:

1. Ask for the project name (default to the repo directory name).
2. Create `graph/`, `raw/`, and `wiki/` directories and a `.research-graph` file containing
   `project = <name>`.
3. Tell the user the automatic SessionStart report begins from their next session (the hook
   already ran when this one opened), while seed, reconcile, and status all work now.

Then populate:

1. Read the project's existing artifacts (READMEs, plans, results, code structure) and ask the
   user to describe the current state where it isn't clear from files.
2. **Propose a node set first, do not write yet.** List proposed nodes as `id, kind, status,
   one-line summary, edges` for the user to correct: pipeline components as `pipeline_node`s with
   honest evidence statuses; in-flight work as `experiment`s; active theories with lifecycle
   stage and `next_gate`; locked methodological choices as `decision`s; plus the `depends_on` /
   `part_of` / `validates` edges between them.
3. Capture **current** state, not full history. One-line forward notes per node, not archaeology.
4. Only after the user approves, write the nodes as `graph/<ID>.md` files per the skill's format.

If `graph/` already has substantial content, don't duplicate; offer to reconcile or extend the
existing graph instead. For a fresh repo with no prior work to read, the scaffold plus a couple of
starter nodes the user names is a fine result.

Seed always runs inline, whatever `background` is set to: its proposal comes back to you for
approval either way, so there is nothing to move off-transcript. Honor `verbosity` in your
summaries.
