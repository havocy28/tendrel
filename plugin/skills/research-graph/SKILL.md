---
name: research-graph
description: >
  Maintain this project's research graph (graph/) and LLM wiki (wiki/, raw/). Use when
  reconciling the graph at a session boundary (the Stop hook points here), when logging an
  experiment/theory/decision/idea/observation as work happens, when linting the graph for
  integrity problems, or when ingesting a dropped source into the wiki. Answers "what depends on
  what / what's validated / what's blocked" from the graph, and "what do we know about X" from the
  wiki.
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

## Configuration (optional)

Three optional keys in `.research-graph` tune behavior. All are additive: if a key is absent, or
its value is unrecognized, tendrel behaves exactly as it did before, so existing projects need no
changes.

- `verbosity = succinct | normal | off` (default `normal`). Controls how much surfaces. The
  SessionStart report side is handled automatically by the hook script. Your side is command
  output: at `succinct`, keep reconcile/status/seed summaries to a line or two; at `off`, stay
  quiet unless something is confidently wrong. Note that `off` also silences the routine
  SessionStart report and disables the proactive reconcile offer, so a user on `off` is
  self-managing drift.
- `background = on | off` (default `off`). When `on`, `status` runs in a dispatched subagent so its
  graph scan stays out of the main transcript. See Background execution below. `seed` and
  `reconcile` always run inline.
- `reconcile = ask | auto` (default `ask`). Whether the reconcile sweep asks before writing. `ask`
  is today's behavior: offer when the report shows drift, write only on approval. `auto` reconciles
  at natural pauses without asking; see Autonomy under the reconcile sweep below. Any other value
  means `ask` (fail closed). Values tolerate a trailing `# comment`, so to stage the key without
  activating it, comment out the whole line. Orthogonal to `background` (which controls where
  output lands, not whether reconcile asks).

**Setting these in-session.** If the user asks to change verbosity, background, or reconcile
autonomy (for example "make the report quieter", "turn on background mode", "turn on auto
reconcile", or "go back to asking before reconciling"), update `.research-graph` yourself: read it, add or update the relevant key while
preserving every other line and comment, write it back, and confirm. `verbosity` takes effect on
your command output immediately; the SessionStart report picks it up at the next session open.
`background` takes effect on the next `status` call; `reconcile` at the next natural pause.

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

**Autonomy.** Default-path gate: if `.research-graph` has no `reconcile` key, or `reconcile = ask`,
or any value other than `auto` (fail closed), behave exactly as described above: offer on drift,
and sweep only on approval. This gate governs the *unprompted sweep*, acting on drift the user did
not just narrate; best-effort live logging of work as the user tells you about it (see the logging
section) is long-standing behavior and is the same under every value of this key. The test is
whose statement prompts the write: work the user tells you about in the conversation is live
logging (write it best-effort under any value); drift you notice by reading files is the sweep,
and this key gates it. This file ships to every project; the `auto` behavior below must not change
anything for anyone who has not opted in.
When `reconcile = auto`, the user has chosen unattended reconcile writes for this repo:

- At session open, if the report shows drift, reconcile right away and summarize what changed in a
  line or two (verbosity-aware) instead of offering.
- At a natural pause (a result lands, a task completes, the topic shifts), fold the work into
  `graph/` without asking. The never-interrupt rule holds unchanged: not mid-task, and never on a
  turn where the user is being asked a question.
- Discovering drift counts as drift. If, while reading the repo (notes, results, code), you see
  that the graph is behind what the files already say, fold that in before you end the turn; do
  not merely describe the mismatch or save it for a later offer. If you are mid-task when you
  notice, finish the user's task first, then fold the drift in at the end of that same turn.
  Under `auto`, "getting up to speed" includes bringing the graph up to speed.
- After each auto reconcile, run the lint (`bash "${CLAUDE_PLUGIN_ROOT}/scripts/graph-lint.sh"`;
  if that variable is unset, locate the plugin's `scripts/graph-lint.sh`) and include the result
  in the summary. Unattended
  writes get the deterministic check; if the lint reports errors, surface them and offer repair per
  the Graph lint section (repairs stay approval-gated even under `auto`).
- Explicit triggers (`/tendrel:reconcile`, "reconcile the graph") behave identically under both
  values.

When reconciling:

1. Compare what happened since the last reconcile against `graph/`. Create/update nodes,
   transition statuses, and add edges so the graph matches reality. Prefer logging live as
   work happens; the reconcile pass is a catch-up, not the only moment to write. When you rewrite
   a node that has edges, put each edge back in the flat one-line form (`- {rel: <relation>, to:
   <target>}`) so it stays readable; this quietly heals any edge that had drifted off-format,
   without a separate pass.
2. **Friction:** if anything about the system was annoying — something you wanted to ask and
   couldn't, something hard to log, ceremony, strained traversal — append it to the tool-global
   friction log at `${CLAUDE_PLUGIN_DATA}/FRICTION.md` (resolves to
   `~/.claude/plugins/data/research-graph-research-graph-local/FRICTION.md`). Tag each entry
   **confidently-wrong** (a reconcile or answer that was definitely incorrect — high priority,
   silent trust erosion) vs **incomplete** (a known gap — lower priority).
3. Make only the reconcile edits, then return to the user — keep the reconcile output terse.

## Background execution (opt-in)

**Default-path gate: if `.research-graph` has no `background` key, or `background = off`, ignore
this entire section and behave exactly as you did before (everything inline).** This gate exists
because this file ships to every project; the instructions below must not change behavior for
anyone who has not opted in.

When `background = on`, run **status** in a dispatched subagent (your Agent/Task tool) and surface
only the result, so the graph scan stays out of the main transcript:

- **status:** dispatch a subagent to read `graph/`, regenerate `status.md`, and return a one-line
  confirmation. Nothing to approve.

**seed and reconcile run inline, whatever `background` is set to.** Reconcile's input is the live
conversation, which a fresh subagent cannot see. Seed produces a proposal the user must review
anyway, so delegating its read-and-draft buys little; it stays inline, reads the project, proposes
a node set, and writes only after the user approves (the approval gate is unchanged). Both may be
backgrounded in a future release once the contract reliably triggers it.

Two honesty rules for background mode:
- It isolates *context*, not wall-clock time. A subagent dispatch is synchronous; the user still
  waits for the operation, they just do not see the scan in their transcript. Do not imply they
  can keep working while it runs.
- On failure, report it and name any files the subagent wrote before failing; never leave a
  partial write silent. If you cannot confirm what landed, say so plainly.

## Graph lint (on demand)

`/tendrel:lint` runs the deterministic `graph-lint.sh` over `graph/`. That script is read-only and
authoritative for *detection*: it checks for dangling edges (a `to:` node ID or `wiki/` path that
does not exist), an edge it cannot read (one not written in the flat one-line form), invalid
`kind`/`status` values, duplicate IDs, `depends_on` cycles, and the key consistency rule, that a
node which `depends_on` an `invalidated` (or already-`blocked`) node must itself be `blocked`. That
rule cascades: because a blocked dependency also triggers it, invalidation must propagate all the
way down a chain, not just one hop. It exits non-zero on errors; warnings (like an empty body) do
not fail.

When the lint reports **error**-severity violations, summarize them and **offer** to fix them; do
not auto-fix. On the user's approval, repair through the normal reconcile behavior:

- invalidation inconsistency: mark the un-blocked downstream node `blocked`, and trace further
  downstream as a reconcile would.
- dangling edge: ask the user which node was meant and re-point the edge, or remove it if they
  confirm it should be dropped. Do not silently delete an edge; the intended target is not
  recoverable from the graph alone.
- unreadable edge: rewrite it in the flat one-line form (`- {rel: <relation>, to: <target>}`).
- invalid `status` or `kind`: correct it to a valid value from the node model.

After you apply an approved repair, **re-run `graph-lint.sh`** and report the result. Repair is
model-driven and its quality is not deterministic, so the deterministic check is what confirms the
fix actually held (and did not introduce a new dangling edge or miss a downstream node). Do not
report a repair as done until a clean lint confirms it. If the re-lint still shows errors (a fix
exposed a further one, or introduced a new one), summarize what remains and offer another repair
cycle; do not keep fixing without approval.

The lint script never writes to `graph/`; only you do, and only after approval. Honor `verbosity`
in the summary.

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
