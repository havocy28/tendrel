# Concepts

Shared domain vocabulary for this project, entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## The graph

### Node
One markdown file in the research graph: structured frontmatter (kind, status, edges, and optional attributes) over a lab-notebook body. Every node has a kind from a fixed set (experiment, theory, pipeline node, decision, idea, observation) and a human-readable ID prefixed by that kind.

### Edge
A directed, typed link from one node to another node or to a wiki page, written inline in the node's frontmatter. The relation vocabulary is extensible; a core set (depends on, validates, invalidated by, supersedes, part of, motivated by, spawned) carries the graph's meaning. The lint checks every edge for a resolvable target, and one relation, depends on, additionally carries lint-enforced lifecycle rules (blocked-status propagation and cycle detection); the rest are vocabulary the model applies during reconcile.

### Provenance
The artifacts a node's numbers come from, declared as a flat list of repo-relative paths in the node's frontmatter. Any kind of node may declare it. Provenance is expected but not enforced when writing; the lint checks that each declared path resolves and warns rather than errors when a path is ignored by git, since such a path vanishes from a clean checkout.

### Claim
In the calibration report, a number a node asserts with at least two decimal places. Integers and one-decimal figures are not claims. A claim-bearing node is one with at least one claim anywhere in its frontmatter or body.

## Processes

### Reconcile
The on-demand sweep that folds recent work into the graph: creating and updating nodes, transitioning statuses, adding edges, and tracing downstream effects of an invalidation. Whether the sweep runs unprompted is a per-repository choice (ask or auto); live logging of work the user narrates is not gated by it.

### Lint
The deterministic, read-only integrity check over the graph: dangling edges, unreadable edges, invalid kinds or statuses, duplicate IDs, dependency cycles, transitive invalidation consistency, and provenance paths that do not resolve. Detection is the script's; repair is model-driven and approval-gated.

### Calibration report
The read-only measurement of how checkable a graph's numbers are against the artifacts they cite: how many nodes carry claims, how many declare provenance, how often a claim is found in its cited artifacts, and how often it would be found in an unrelated artifact by coincidence (the null test). It exists so the decision to build a number-matching check rests on evidence from more than one graph.

### Friction log
The tool-global file where the agent records what was hard or wrong about using the graph during a reconcile, tagged as confidently-wrong (a definite error, high priority) or incomplete (a known gap). It is the maintainer's demand signal.
