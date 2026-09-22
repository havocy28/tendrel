# Concepts

Shared domain vocabulary for this project, entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## The graph

### Node
One markdown file in the research graph: structured frontmatter (kind, status, edges, and optional attributes) over a lab-notebook body. Every node has a kind from a fixed set (experiment, theory, pipeline node, decision, idea, observation) and a human-readable ID prefixed by that kind.

### Edge
A directed, typed link from one node to another node or to a wiki page, written inline in the node's frontmatter. The relation vocabulary is extensible; a core set (depends on, validates, invalidated by, supersedes, part of, motivated by, spawned) carries the graph's meaning. The lint checks that every edge's target resolves (a node ID, or a repo-relative path validated the way provenance is), enforces the lifecycle rules of depends on (blocked-status propagation and cycle detection), and rejects mutual or self-referencing invalidated by, supersedes, and part of edges, whose direction carries their meaning; the remaining relations are vocabulary the model applies during reconcile.

### Provenance
The artifacts a node's numbers come from, declared as a flat list of repo-relative paths in the node's frontmatter. Any kind of node may declare it. Provenance is expected but not enforced when writing; the lint checks that each declared path resolves and warns rather than errors when a path is ignored by git, since such a path vanishes from a clean checkout.

### Claim
In the calibration report, a number a node asserts with at least two decimal places. Integers and one-decimal figures are not claims. A claim-bearing node is one with at least one claim anywhere in its frontmatter or body.

### Pre-registered exit
The optional `abandon_if` value an experiment declares before it runs: the number or outcome that would make the researcher drop the line. Its companions are `compared_to` (the null or comparison group) and `bound` (the effect size a null excludes). A null result with no bound is uninformative and cannot be cited to conclude or refute; a bounded null is an output in hand. How an `abandon_if` was resolved is recorded as a flat `exit_outcome` marker, `crossed` or `overridden`, with the value or the reason in the body; the experiment stays complete with its real result either way, and an override is never re-raised.

### Deferred
A status for an idea or an experiment that is worth running later but not now, kept with a `reopen_when` trigger (a node reaching a status, a count, or an outside event). Deferred is a choice; blocked is a consequence, something a failed dependency does to a pipeline node, and applies only to ideas and experiments. A deferred item is listed as waiting on its trigger and is never proposed until the trigger has fired.

## Processes

### Reconcile
The on-demand sweep that folds recent work into the graph: creating and updating nodes, transitioning statuses, adding edges, and tracing downstream effects of an invalidation. Whether the sweep runs unprompted is a per-repository choice (ask or auto); live logging of work the user narrates is not gated by it.

### Lint
The deterministic, read-only integrity check over the graph: dangling edges (to node IDs or to repo-relative paths), unreadable edges, mutual or self-referencing direction-carrying edges, invalid kinds or statuses, duplicate IDs, dependency cycles, transitive invalidation consistency, and provenance paths that do not resolve. Its explain mode renders each edge with its target's first line so a wrong target is visible on sight. Detection is the script's; repair is model-driven and approval-gated.

### Calibration report
The read-only measurement of how checkable a graph's numbers are against the artifacts they cite: how many nodes carry claims, how many declare provenance, how often a claim is found in its cited artifacts, and how often it would be found in an unrelated artifact by coincidence (the null test). It exists so the decision to build a number-matching check rests on evidence from more than one graph.

### Background execution
The opt-in mode that runs the status scan in a dispatched subagent so it stays out of the main transcript. Off by default per repository. Only work whose result the user does not need to see mid-flight is dispatched; proposal-producing operations stay inline because their output must come back to the user anyway. It isolates context, not wall-clock time.

### Friction log
The tool-global file where the agent records what was hard or wrong about using the graph during a reconcile, tagged as confidently-wrong (a definite error, high priority) or incomplete (a known gap). It is the maintainer's demand signal.

### Verdict
The closing judgment of the next brief, on one body line: continue (proposals follow, each with the losing outcome that would end it), conclude (what stands, what it rests on, what would reopen it), or wait (what unlocks the work, listing every trigger). The pre-check decides first when it can: a futility finding forces wait with no judgment call, and a graph with nothing open or deferred forces conclude or continue, never wait. Otherwise the model judges under a burden of proof: a continue names, in the footer's "Verdict rests on:" line, at least one non-terminal node (a planned or running experiment, an open idea, or a theory with an unmet gate) whose next result would change what the graph says, since a complete, abandoned, invalidated, dropped, or shelved node cannot discriminate; a conclude or wait names the nodes whose evidence settles the line or whose triggers gate it. A verdict is advice: next writes nothing to the graph under it.

### Pre-check
The deterministic layer of the verdict: the lint's `--precheck` flag, which enumerates, from committed graph state alone, one line per finding with a stable prefix: `STALE_GATE` (a gate naming a node that has reached a terminal status), `GATE_CONTEXT` (completed experiments attached to a theory, context only, never a finding), `EXIT_PENDING` and `EXIT_CROSSED` (an unresolved or a crossed pre-registered exit), `DEFERRED` and `FIRED` (a deferred item, and, when its trigger has been met, that too), and a closing `FUTILITY` or `JUDGMENT` summary, or the literal `precheck: silent` when nothing fires. It enumerates and never judges: whether a gate that names a finished node has actually been met, or a result crossed its exit, is the agent's call from the quoted lines, made at reconcile time and recorded as a flat exit outcome on the experiment.
