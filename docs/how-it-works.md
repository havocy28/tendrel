# How tendrel works

Tendrel is a thin Claude Code plugin over plain markdown. There is no server, no database, and no
background process, just a hook, a skill, and the files in your repo. This doc explains the
mechanics end to end.

## The two layers

- **Research graph** (`graph/`) holds work *state*. One markdown file per typed node
  (`graph/<ID>.md`): YAML frontmatter carries the structured fields and edges, the body is your
  lab notebook. See [`node-model.md`](node-model.md).
- **LLM wiki** (`wiki/`, fed from `raw/`) holds reference *knowledge*. Drop a source in `raw/`, ask
  the agent to fold it into `wiki/` concept pages, then query the page instead of re-deriving.

They cross-link (a node's edge `to:` can be a `wiki/` path) but stay distinct: the graph answers
"what depends on what / what's validated / what's blocked," the wiki answers "what do we know
about X."

## What's automatic: the SessionStart hook

The plugin registers exactly one hook, `SessionStart`, which runs
`scripts/session-start-report.sh` when a session opens.

- **Scope guard.** It does nothing unless the session's working directory has a `graph/`
  directory. That's what makes the plugin safe to leave installed globally: it's inert in every
  repo that isn't a tendrel project.
- **What it emits.** It reads `graph/*.md` frontmatter and injects an anomaly-led report as
  `additionalContext`: node count, nodes with empty bodies (claimed but unlogged), `depends_on`
  edges pointing at a missing node (a Stage-1 trigger candidate), open theories, and
  unvalidated/blocked pipeline nodes, then a reminder that reconcile is on-demand.

That's the whole of the automatic behavior. There is no `Stop` hook: an earlier version
reconciled after every turn and hijacked turns where the agent had paused to ask a question, so it
was removed (see [`history/SPIKE.md`](history/SPIKE.md)).

## What the skill teaches

The `research-graph` skill (`plugin/skills/research-graph/SKILL.md`) is the behavior contract. It
teaches Claude the node kinds, statuses, ID scheme, edge vocabulary, what a reconcile sweep does,
the wiki loop, and how to generate `status.md`. Both the slash commands and natural-language
requests route through it: it is the single source of truth for behavior.

## Reconciliation (on demand)

Reconcile runs when you ask, via `/tendrel:reconcile` or *"reconcile the graph."* It:

1. Compares what's happened since the last reconcile against `graph/`.
2. Creates/updates nodes, transitions statuses, and adds edges so the graph matches reality.
3. Traces downstream on any invalidation and reports what's now affected.
4. Appends any system friction to the friction log.
5. Keeps its output terse and returns control to you.

Because nothing forces it, the SessionStart report is the drift backstop: if the graph looks
behind at session open, that's your cue to reconcile.

## Graph lint (on demand)

`/tendrel:lint` runs a deterministic, read-only script (`plugin/scripts/graph-lint.sh`) over
`graph/`. This is a deliberate split: **detection is a script, repair is the model.** Integrity is
load-bearing, so detection is deterministic and never subject to a reasoning lapse; the script
flags dangling edges, invalid kinds or statuses, duplicate IDs, `depends_on` cycles, and the
invalidation-consistency rule. That rule is transitive: a node that `depends_on` an `invalidated`
(or already-`blocked`) node must itself be `blocked`, so an invalidation that only propagated one
level down a chain still fails the check. It exits non-zero on errors and never writes to `graph/`.

Repair is judgment, so it stays with the model and stays approval-gated. On error-severity
violations, Claude summarizes them and offers to fix them through the same reconcile behavior it
uses everywhere else; it writes only after you approve, and then re-runs the lint so the
deterministic check confirms the fix held. The script is safe to wire into CI as a
gate, since a broken graph fails the run while advisory warnings do not.

## status.md

`/tendrel:status` regenerates `status.md` from `graph/`: a mermaid diagram of the actual graph plus
grouped text sections. It's generated fresh each time, never hand-maintained (a maintained summary
drifts). See a rendered example: [`../examples/doc-search/status.md`](../examples/doc-search/status.md).

## Configuration and background execution

Two optional keys in `.research-graph` (`verbosity` and `background`) tune behavior, and both are
additive: absent means today's behavior, so existing projects are unaffected.

**Verbosity** (`succinct | normal | off`, default `normal`) controls how much surfaces. The
SessionStart report honors it directly in the hook script; commands honor it in their summaries.
`off` is deliberately more than silence: since the per-turn Stop hook was removed in v0.0.3, the
SessionStart report is the only automatic drift signal, so `off` still surfaces confidently-wrong
anomalies (dangling edges, empty-body nodes) and disables the proactive reconcile offer. Choosing
`off` means you are self-managing drift.

**Background** (`on | off`, default `off`) runs `status` in a dispatched subagent, so its graph
scan stays out of your main transcript. It isolates *context*, not wall-clock time: a subagent
dispatch is synchronous, so you still wait for the operation; you just do not see the scan. It does
not let you keep working while it runs.

`seed` and `reconcile` run inline. Reconcile's input is the live conversation, which a fresh
subagent cannot see. Seed produces a proposal you review before anything is written, so delegating
its read buys little and (measured) does not reliably trigger; it stays inline with its approval
gate intact. Both may be backgrounded in a future release once the contract reliably triggers.

## Plugin data (`CLAUDE_PLUGIN_DATA`)

Tool-global state lives outside your repos, in the plugin's data directory:

- `FRICTION.md` is the friction log, appended during reconciles, tagged **confidently-wrong**
  (high priority, silent trust erosion) vs **incomplete** (a known gap). This is the signal that
  fires the roadmap: promotions are triggered by logged friction, not the calendar.

## Roadmap triggers

- **SQLite + MCP server** (added to this same plugin) when the `depends_on -> missing node` audit
  fires repeatedly, or file-scan traversal over the graph strains.
- **Wiki search** when the wiki outgrows plain file-reading.
