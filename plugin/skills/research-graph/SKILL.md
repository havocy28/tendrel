---
name: research-graph
description: >
  Maintain this project's research graph (graph/) and LLM wiki (wiki/, raw/). Use when
  reconciling the graph at a session boundary (the Stop hook points here), when logging an
  experiment/theory/decision/idea/observation as work happens, or when ingesting a dropped
  source into the wiki. Answers "what depends on what / what's validated / what's blocked"
  from the graph, and "what do we know about X" from the wiki.
---

# Research graph + LLM wiki — maintenance contract

You maintain two layers for this project. The **graph** (`graph/`) tracks work *state* —
what depends on what, what's validated, what's blocked. The **wiki** (`wiki/`, fed from
`raw/`) holds *reference* knowledge — what we know about a topic. They cross-link but stay
distinct.

## Scaffolding a repo (in-session)

Tendrel operates in any repo that has a `graph/` directory. If a user asks to set up, initialize,
or seed tendrel in a repo that has none, scaffold it yourself in the session. Do not send them to
a terminal or a shell script:

1. Ask for the project name (default: the repo directory name).
2. Create `graph/`, `raw/`, and `wiki/` directories and a `.research-graph` file containing
   `project = <name>`.
3. Note that the automatic SessionStart report begins from the next session (the hook already ran
   when this one opened); seed, reconcile, and status all work immediately.

The bundled `setup-research-repo.sh` does the same thing from the command line and is only a
convenience for scaffolding many repos at once.

## The graph: one markdown file per node

Each node is `graph/<ID>.md`: YAML frontmatter carries the structured fields and edges; the
body is a lab-notebook log.

```markdown
---
id: EXP-012
kind: experiment
status: complete
question: "Does Sonnet zero-shot match PetBERT on disease NER?"
config: {model: sonnet, dataset: peteval-ner, n: 500}
result: "F1 0.87 vs PetBERT 0.84"
edges:
  - {rel: part_of, to: THEORY-002}
  - {rel: validates, to: DEC-003}
  - {rel: spawned, to: IDEA-007}
---
Ran with the v2 prompt. 3 misses traced to Australian drug abbreviations — see OBS-004.
```

**Frontmatter stays flat — one field per line, no multi-line or nested YAML values** (the
hook scripts parse it with simple line matching; nested YAML would be misread silently).
`config`/`edges` inline-map and inline-list forms above are fine; do not break them across
lines.

### Node kinds, statuses, IDs

| Kind | ID prefix | What it is | `status` vocabulary |
|---|---|---|---|
| `experiment` | `EXP-` | A concrete thing you ran, with a question and a result | `planned` · `running` · `complete` · `abandoned` |
| `theory` | `THEORY-` | A hypothesis container with a lifecycle | `idea` · `backtest` · `paper_trade` · `live_small` · `live_full` · `shelved` |
| `pipeline_node` | `NODE-` | A system component whose correctness is open | `untested` · `assumed_working` · `validated` · `invalidated` · `blocked` |
| `decision` | `DEC-` | A methodological choice, with its evidence | `active` · `under_review` · `reversed` |
| `idea` | `IDEA-` | Something to maybe try later | `open` · `promoted` · `dropped` |
| `observation` | `OBS-` | A pattern/anomaly noticed; no lifecycle | (none) |

Per-kind attributes (expected, not enforced): `experiment` → `question`, `config`;
`theory` → `confidence` (low/moderate/high), `next_gate`; `pipeline_node` → optional `eval`.

**IDs** are human-readable, zero-padded, per-(project, kind): `EXP-001`, `THEORY-001`. To
assign the next ID for a kind, glob `graph/<PREFIX>-*.md` and take max + 1. Reference nodes
by ID in prose ("blocked on `NODE-003`") so the graph stays legible in conversation.

### Edge vocabulary (directed; `relation` is an extensible string)

| Relation | Reads as | Use |
|---|---|---|
| `depends_on` | A depends_on B | A can't proceed/be trusted until B is done/validated. Also models "blocked by." |
| `validates` | A validates B | A is evidence supporting B. |
| `invalidated_by` | A invalidated_by B | Evidence B undermines A. |
| `supersedes` | A supersedes B | A replaces B; treat B as historical. |
| `part_of` | A part_of B | A belongs to container B (experiment → theory). |
| `motivated_by` | A motivated_by B | B (observation/result/wiki page) is why A exists. |
| `spawned` | A spawned B | Working on A produced B. |

An edge `to:` target may be a node ID **or** a `wiki/` path (cross-layer link). The graph
records the link; the content lives in the wiki file.

## What logging looks like (best-effort, in-session)

- **Starting an experiment** → create `graph/EXP-<n>.md` (frontmatter: kind, question,
  config), status `running`. On finish → set `result` and status `complete`/`abandoned`,
  add edges: `part_of` the relevant theory, `validates`/`invalidated_by` any decision.
- **A methodological choice** → a `decision` node with edges to the experiments that
  justify it. Reversing it → set the old one `reversed`, create the new one, add
  `supersedes` with a one-line reason.
- **Building a pipeline** → each component is a `pipeline_node` with an evidence `status`
  and `depends_on` edges upstream. When one fails validation, scan for nodes whose edges
  point at it (downstream) and report what's affected (best-effort; log misses to friction).
- **An idea mid-task** → an `idea` node with a `motivated_by` edge to what you're doing.
- **A node may rest on background knowledge** → add an edge whose `to:` is a `wiki/` page.

## The reconcile sweep (on-demand)

As of v0.0.3, reconciliation is **on-demand**, not auto-fired every turn — it runs when the
user says "reconcile the graph," or when you proactively offer after the SessionStart report
shows the graph is behind (e.g. stale statuses, empty-body nodes). It must never interrupt the
user mid-task or hijack a turn where they're being asked a question.

When reconciling:

1. Compare what happened since the last reconcile against `graph/`. Create/update nodes,
   transition statuses, and add edges so the graph matches reality. Prefer logging live as
   work happens; the reconcile pass is a catch-up, not the only moment to write.
2. **Friction:** if anything about the system was annoying — something you wanted to ask and
   couldn't, something hard to log, ceremony, strained traversal — append it to the tool-global
   friction log at `${CLAUDE_PLUGIN_DATA}/FRICTION.md` (resolves to
   `~/.claude/plugins/data/research-graph-research-graph-local/FRICTION.md`). Tag each entry
   **confidently-wrong** (a reconcile or answer that was definitely incorrect — high priority,
   silent trust erosion) vs **incomplete** (a known gap — lower priority).
3. Make only the reconcile edits, then return to the user — keep the reconcile output terse.

## The wiki (reference layer — native file ops, nothing to build)

- **Ingest:** when a source lands in `raw/`, read it and fold the relevant content into the
  right `wiki/` page(s), creating pages as needed. Pages are concise summaries / concept
  notes / timelines, interlinked with relative paths or `[[wikilinks]]`.
- **Query:** when asked "what do we know about X," read the relevant `wiki/` page rather than
  re-deriving from `raw/` sources.

## status.md (generated on demand, never hand-maintained)

On request, generate `status.md` from `graph/`: theories grouped by lifecycle stage with
confidence and next gate; pipeline nodes grouped by evidence status; reversed decisions with
reasons; open ideas. One screen. Regenerate it; do not maintain it by hand (a maintained
summary drifts).

### The graph visualization (a mermaid diagram of the actual nodes)

`status.md` opens with a `mermaid` flowchart built from the real `graph/` — the visual
interface to the graph itself. Build it by reading the same frontmatter the text sections read:

- **One node per graph node.** Label it `<ID>\n<short title>`. Shape/style by kind + status:
  - `pipeline_node` `validated` → solid box; `assumed_working` → box, dotted border;
    `untested` → box; `invalidated` → **red fill**; `blocked` → **orange/dashed**.
  - `theory` → rounded (stadium) node, append its lifecycle stage (e.g. `(backtest)`).
  - `experiment` / `decision` / `idea` / `observation` → default nodes; keep them present but
    visually quieter than theories and pipeline nodes.
  - Apply mermaid `classDef` + `class` for the invalidated/blocked/validated styles so the
    states read at a glance; keep the palette to a few classes, not per-node styling.
- **One edge per graph edge**, arrow from source → target, labeled with the relation
  (`depends_on`, `validates`, `invalidated_by`, `supersedes`, `part_of`, `motivated_by`,
  `spawned`). A `depends_on` target that has no node file is a dangling edge — render it to a
  dashed placeholder node or omit it (consistent with the SessionStart edge-symmetry audit),
  never crash the diagram.
- **Readability guard (large graphs).** If the graph exceeds a node-count threshold (start at
  ~25; tune to taste), do not emit the full graph — scope the diagram to theories,
  pipeline_nodes, and their direct dependencies, and add a caption line
  `> N nodes omitted — full inventory in the sections below.` The text sections always list
  every node regardless.
- **Empty graph** (0 nodes) → emit the text sections with no mermaid block (or a one-line
  "no nodes yet"), never an empty/broken diagram.

Keep the diagram top-down (`flowchart TB`) so it stays narrow. It complements the grouped text
sections; it does not replace them.

Before proposing what to try next, check open theories and unvalidated pipeline nodes so you
don't re-run something already done.
