# Recipes

Task-shaped walkthroughs. All of these are just things you say (or slash commands) — the
`research-graph` skill does the work.

## Seed an existing project from reality

You have a project with real work but an empty graph. Run `/tendrel:seed` (or *"seed the graph"*).
The guided flow:

1. Reads your READMEs, plans, results, and code structure, and asks you to fill gaps.
2. **Proposes a node set — pipeline components as `pipeline_node`s with honest evidence statuses,
   in-flight work as `experiment`s, active theories with `next_gate`, locked choices as
   `decision`s — for your review before writing anything.**
3. Captures *current* state (one-line forward notes), not full history.
4. Writes the approved nodes to `graph/`.

Don't skip the review step — the graph is only trustworthy if it reflects your actual project,
not plausible guesses.

## The daily loop

1. Open a session — read the SessionStart report (open theories, blocked nodes, anomalies).
2. Do your work; reference nodes by ID.
3. At a natural pause: `/tendrel:reconcile` — it folds the session's work into the graph.
4. `/tendrel:status` when you want the one-screen view + graph diagram.

Reconcile at pauses, not after every message — nothing forces it, so pick the moments where
there's something worth logging.

## Handle a failed eval (invalidation + downstream trace)

You finally evaluate a component and it fails. Tell the agent, or reconcile:

> "The reconciliation node fails — it drops 40% of cross-source matches. Mark it invalidated and
> tell me what's affected."

The agent sets the `pipeline_node` to `invalidated` with a note, then traces every node whose
edges point at it (downstream) and reports what's now `blocked` or untrustworthy — so you see in
one step what work is dead until the component is fixed. `/tendrel:status` will then render those
nodes in the invalidated/blocked styles.

## Ingest a source into the wiki

Drop a paper, export, or notes into `raw/`, then:

> "Fold `raw/farrell-2024.pdf` into the wiki."

The agent creates or updates the right `wiki/` concept page. Later, *"what do we know about the
PetEVAL gold standard?"* reads that page instead of re-reading the source. A graph node can point
at a wiki page with an edge (`{rel: motivated_by, to: wiki/peteval.md}`) when it rests on that
background knowledge.

## Read the status view

`/tendrel:status` regenerates `status.md`: a mermaid diagram of the graph (dependency arrows,
invalidated/blocked nodes highlighted, theories showing lifecycle stage) plus grouped text
sections. Browse a rendered example at
[`../examples/doc-search/status.md`](../examples/doc-search/status.md). It's generated fresh —
never hand-edit it.
