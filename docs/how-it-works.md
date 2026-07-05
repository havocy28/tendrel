# How tendrel works

Tendrel is a thin Claude Code plugin over plain markdown. There is no server, no database, and
no background process — just a hook, a skill, and the files in your repo. This doc explains the
mechanics end to end.

## The two layers

- **Research graph** (`graph/`) — work *state*. One markdown file per typed node
  (`graph/<ID>.md`): YAML frontmatter carries the structured fields and edges, the body is your
  lab notebook. See [`node-model.md`](node-model.md).
- **LLM wiki** (`wiki/`, fed from `raw/`) — reference *knowledge*. Drop a source in `raw/`, ask
  the agent to fold it into `wiki/` concept pages, then query the page instead of re-deriving.

They cross-link (a node's edge `to:` can be a `wiki/` path) but stay distinct: the graph answers
"what depends on what / what's validated / what's blocked," the wiki answers "what do we know
about X."

## What's automatic: the SessionStart hook

The plugin registers exactly one hook — `SessionStart` — which runs
`scripts/session-start-report.sh` when a session opens.

- **Scope guard.** It does nothing unless the session's working directory has a `graph/`
  directory. That's what makes the plugin safe to leave installed globally: it's inert in every
  repo that isn't a tendrel project.
- **What it emits.** It reads `graph/*.md` frontmatter and injects an anomaly-led report as
  `additionalContext`: node count, nodes with empty bodies (claimed but unlogged), `depends_on`
  edges pointing at a missing node (a Stage-1 trigger candidate), open theories, and
  unvalidated/blocked pipeline nodes — then a reminder that reconcile is on-demand.

That's the whole of the automatic behavior. There is no `Stop` hook: an earlier version
reconciled after every turn and hijacked turns where the agent had paused to ask a question, so
it was removed (see [`history/SPIKE.md`](history/SPIKE.md)).

## What the skill teaches

The `research-graph` skill (`plugin/skills/research-graph/SKILL.md`) is the behavior contract.
It teaches Claude the node kinds, statuses, ID scheme, edge vocabulary, what a reconcile sweep
does, the wiki loop, and how to generate `status.md`. Both the slash commands and natural-language
requests route through it — it is the single source of truth for behavior.

## Reconciliation (on demand)

Reconcile runs when you ask — `/tendrel:reconcile` or *"reconcile the graph."* It:

1. Compares what's happened since the last reconcile against `graph/`.
2. Creates/updates nodes, transitions statuses, and adds edges so the graph matches reality.
3. Traces downstream on any invalidation and reports what's now affected.
4. Appends any system friction to the friction log.
5. Keeps its output terse and returns control to you.

Because nothing forces it, the SessionStart report is the drift backstop: if the graph looks
behind at session open, that's your cue to reconcile.

## status.md

`/tendrel:status` regenerates `status.md` from `graph/` — a mermaid diagram of the actual graph
plus grouped text sections. It's generated fresh each time, never hand-maintained (a maintained
summary drifts). See a rendered example: [`../examples/doc-search/status.md`](../examples/doc-search/status.md).

## Plugin data (`CLAUDE_PLUGIN_DATA`)

Tool-global state lives outside your repos, in the plugin's data directory:

- `FRICTION.md` — the friction log, appended during reconciles, tagged **confidently-wrong**
  (high priority — silent trust erosion) vs **incomplete** (a known gap). This is the signal that
  fires the roadmap: promotions are triggered by logged friction, not the calendar.

## Roadmap triggers

- **SQLite + MCP server** (added to this same plugin) — when the `depends_on → missing node`
  audit fires repeatedly, or file-scan traversal over the graph strains.
- **Wiki search** — when the wiki outgrows plain file-reading.
