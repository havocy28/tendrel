# Recipes

Task-shaped walkthroughs. All of these are just things you say (or slash commands); the
`research-graph` skill does the work.

## Seed an existing project from reality

You have a project with real work but an empty graph. Run `/tendrel:seed` (or *"seed the graph"*).
The guided flow:

1. Reads your READMEs, plans, results, and code structure, and asks you to fill gaps.
2. **Proposes a node set (pipeline components as `pipeline_node`s with honest evidence statuses,
   in-flight work as `experiment`s, active theories with `next_gate`, locked choices as
   `decision`s) for your review before writing anything.**
3. Captures *current* state (one-line forward notes), not full history.
4. Writes the approved nodes to `graph/`.

Don't skip the review step. The graph is only trustworthy if it reflects your actual project, not
plausible guesses.

## The daily loop

1. Open a session; read the SessionStart report (open theories, blocked nodes, anomalies).
2. Do your work; reference nodes by ID.
3. At a natural pause: `/tendrel:reconcile`, which folds the session's work into the graph.
4. `/tendrel:status` when you want the one-screen view plus graph diagram.

Reconcile at pauses, not after every message. Nothing forces it, so pick the moments where
there's something worth logging.

## Handle a failed eval (invalidation plus downstream trace)

You finally evaluate a component and it fails. Tell the agent, or reconcile:

> "The reconciliation node fails: it drops 40% of cross-source matches. Mark it invalidated and
> tell me what's affected."

The agent sets the `pipeline_node` to `invalidated` with a note, then traces every node whose
edges point at it (downstream) and reports what's now `blocked` or untrustworthy, so you see in
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
[`../examples/doc-search/status.md`](../examples/doc-search/status.md). It's generated fresh, never
hand-edited.

## Decide what to run next

When you are mid-investigation and need to weigh everything found and done so far, ask
`/tendrel:next` (or "what should we run next?"). It lints the graph, reads the whole history, and
gives you a plain-language brief of where things stand plus 2-3 concrete next-experiment proposals,
each with why it's the right move now and what to skip because the graph already ruled it out. It
reads like a colleague catching you up, not a list of node IDs, and it writes nothing: it is advice
you act on, not state on disk. A skippable "Where this came from" footer maps each claim back to the
nodes behind it if you want to check one.
