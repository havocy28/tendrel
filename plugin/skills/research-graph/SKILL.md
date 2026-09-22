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
provenance: [results/exp-012-ner.md]
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
| `experiment` | `EXP-` | A concrete thing you ran, with a question and a result | `planned` · `running` · `complete` · `abandoned` · `deferred` |
| `theory` | `THEORY-` | A hypothesis container with a lifecycle | `idea` · `backtest` · `paper_trade` · `live_small` · `live_full` · `shelved` |
| `pipeline_node` | `NODE-` | A system component whose correctness is open | `untested` · `assumed_working` · `validated` · `invalidated` · `blocked` |
| `decision` | `DEC-` | A methodological choice, with its evidence | `active` · `under_review` · `reversed` |
| `idea` | `IDEA-` | Something to maybe try later | `open` · `promoted` · `dropped` · `deferred` |
| `observation` | `OBS-` | A pattern/anomaly noticed; no lifecycle | (none) |

`deferred` is a choice, not a consequence: the item is worth keeping but not worth running yet
(`blocked` is what a failed dependency does to a pipeline node). It applies to ideas and
experiments only.

Per-kind attributes (expected, not enforced): `experiment` → `question`, `config`;
`theory` → `confidence` (low/moderate/high), `next_gate`; `pipeline_node` → optional `eval`.
An `experiment` also accepts four optional flat fields. `abandon_if` is the pre-registered number
or outcome that ends the line, written before the run. `compared_to` is the null or comparison
group the result is measured against. `bound` is the effect size a null result excludes; a null
without one is uninformative. `exit_outcome` records how an `abandon_if` was resolved: `crossed`
or `overridden`, each with the value or the reason in the body. An `idea` or `experiment` with
`status: deferred` also accepts `reopen_when`: the node form is exactly `<NODE-ID> <status>` and is
evaluated by the scripts; any other value is a text trigger, listed and never evaluated. Unknown
or absent values behave as before: a node without these fields reads exactly as it did, and an
`exit_outcome` outside the two values reads as absent.

`provenance` (any kind, expected, not enforced): a flat list of repo-relative paths naming the
artifacts the node's numbers come from, e.g. `provenance: [results/exp-012-ner.md]`. Write the
inline list form; the lint also reads a bare scalar and a block list (one `- path` per line, like
`edges:`), so a hand-edited node in either form still gets checked. Declare it whenever a node
states a precise figure. The lint checks that every declared path resolves; a
git-ignored path (`raw/`, `work/`) is a warning rather than an error, because it vanishes from a
clean checkout.

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

`invalidated_by`, `supersedes`, and `part_of` carry their whole meaning in their direction: the
lint rejects two nodes that each claim the other with the same relation, and a node that points at
itself. Put the edge on the node whose reading changes (the undermined experiment carries
`invalidated_by`), never on both.

An edge `to:` target may be a node ID **or** a repo-relative path (a `wiki/` page, the plan document
that motivated the node, a results file). The graph records the link; the content lives in the
file. The lint checks that a node target exists and that a path target resolves the way a
`provenance:` path does: tracked and present is silent, present but untracked warns, matched by
the repo `.gitignore` is silent, missing is an error. Quote a path that contains spaces. Refer to
a node by its ID, never by its file path; a `graph/<ID>.md` target is an error naming the ID.

## What logging looks like (best-effort, in-session)

- **Starting an experiment** → create `graph/EXP-<n>.md` (frontmatter: kind, question,
  config), status `running`. When the experiment comes from a `next` proposal,
  carry the proposal's losing outcome into `abandon_if` when you create the node; when it has a
  null or comparison group, write `compared_to`. An exit written at creation is a
  pre-registration; one written after the result is a rationalization. On finish → set `result`
  and status `complete`/`abandoned`, add edges: `part_of` the relevant theory,
  `validates`/`invalidated_by` any decision.
- **Recording a number** (a `result`, a metric, a count in the body) → read the number out of
  the artifact that produced it (the results file, table, or log on disk) rather than restating
  it from conversation or memory, and name that artifact in `provenance:`. Transcription is where
  drift enters: a node quoting `p=0.94` while its results file holds `0.9487862` is the failure
  this prevents. If no artifact holds the number, say so in the body ("hand-computed", "reported
  verbally") rather than lending it false precision. This is a write-time habit, never a prompt;
  nothing here interrupts the user.
- **Linking to another node** → before writing the first edge to a target in a sweep or turn,
  read the target's first body line; a node you read or wrote earlier in the same sweep counts as
  read. An ID guessed from memory is how a `validates` edge once landed on an unrelated decision.
  This is a write-time habit, never a prompt.
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
- After each auto reconcile, run the lint (`bash "${CLAUDE_PLUGIN_ROOT}/scripts/graph-lint.sh"
  --precheck .`; if that variable is unset, locate the plugin's `scripts/graph-lint.sh`) and
  include the result in the summary. Unattended
  writes get the deterministic check; if the lint reports errors, surface them and offer repair per
  the Graph lint section (repairs stay approval-gated even under `auto`). Read the `PRECHECK:`
  block after the sweep; each `EXIT_PENDING` and `FIRED` line is a proposal per the Graph lint
  section, whether or not this sweep caused it.
- An exit stays approval-gated even under `auto`. When you record a result for an experiment
  carrying `abandon_if` and no `exit_outcome`, compare the result to the exit as a judgment (the
  result is free text; nothing deterministic decides this). When it crossed, propose writing
  `exit_outcome: crossed`, with the crossed value in the body, as a separate yes or no at the end
  of the turn: never bundled into a batch approval, and never applied under any `reconcile`
  value. A narrated result is never a yes: when the user reports the number and even says it fell
  below the line, that is the result being logged, not an answer to a proposal you have not made
  yet, so write the marker only after they answer the yes or no. The experiment stays `complete`
  with its real result either way. A decline writes `exit_outcome: overridden` with the reason in
  the body, so the exit is never re-raised. Ending the line (dropping the idea, shelving the
  theory) is a further, separate proposal.
- Reopening stays approval-gated even under `auto`. A fired trigger (the pre-check's `FIRED` line,
  or the session-start report's "Deferred, trigger fired" line) is proposed, never applied, under
  every `reconcile` value: propose moving the item back to `open` or `planned`, and leave it
  `deferred` until the user says so. A trigger the user declines stays listed as fired until the
  item's status or trigger changes.
- Explicit triggers (`/tendrel:reconcile`, "reconcile the graph") behave identically under both
  values.

When reconciling:

1. Compare what happened since the last reconcile against `graph/`. Create/update nodes,
   transition statuses, and add edges so the graph matches reality. Prefer logging live as
   work happens; the reconcile pass is a catch-up, not the only moment to write. When you rewrite
   a node that has edges, put each edge back in the flat one-line form (`- {rel: <relation>, to:
   <target>}`) so it stays readable; this quietly heals any edge that had drifted off-format,
   without a separate pass. When a node you create or update carries a numeric `result` or a
   precise figure in its body, copy it from the cited artifact and declare that artifact in
   `provenance:` (see the logging section); never restate a number from conversation when the
   file that produced it is on disk.
   A deferral is a status and a trigger, never a body note. When an idea or a planned experiment
   is parked (not worth running at the current sample size, gated on something outside the graph),
   set `status: deferred` and write `reopen_when`. The node form `<NODE-ID> <status>` (for example
   `reopen_when: EXP-003 complete`) is what the scripts evaluate; anything else is a text trigger,
   listed by the pre-check and `status.md` but never evaluated by a script. A blocker written only
   in prose is invisible to every surface that reads triggers.
   When you transition a node's status, look for `reopen_when` lines naming that ID and
   propose reopening each match in the same turn, as the reopen bullet above describes; the
   proposal is the sweep's, the decision is the user's.
   After writing or changing edges, and before ending the sweep, run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/graph-lint.sh" --explain . <touched node IDs>` (if the
   variable is unset, locate the plugin's `scripts/graph-lint.sh`) and review each rendered line:
   an edge whose target summary does not match the claim you meant to make is corrected before
   the sweep ends. This applies under `reconcile = ask` and `reconcile = auto` alike and never
   prompts the user.
2. **Friction:** if anything about the system was annoying — something you wanted to ask and
   couldn't, something hard to log, ceremony, strained traversal — append it to the tool-global
   friction log at `${CLAUDE_PLUGIN_DATA}/FRICTION.md` (resolves to
   `~/.claude/plugins/data/tendrel-tendrel/FRICTION.md` for a marketplace install; a legacy local
   install used `research-graph-research-graph-local`). Tag each entry
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
`kind`/`status` values, duplicate IDs, `depends_on` cycles, the key consistency rule, that a
node which `depends_on` an `invalidated` (or already-`blocked`) node must itself be `blocked`,
that every `provenance:` path resolves (a git-ignored path is a warning, not an error), mutual or
self-referencing `invalidated_by`, `supersedes`, and `part_of` edges (direction carries their
meaning, so two nodes each claiming the other is always wrong), and edge targets that are
repo-relative paths (a tracked path resolves silently, an untracked present path warns, a path
matched by the repo `.gitignore` is silent, a missing path errors). The consistency rule cascades:
because a blocked dependency also triggers it, invalidation must propagate all the way down a
chain, not just one hop. It exits non-zero on errors; warnings (like an empty body) do not fail.
It also warns, never errors, on a planned experiment that has a `config` and no `abandon_if`, on a
complete experiment carrying a `validates` edge with no `compared_to`, and on a node-form
`reopen_when` naming a node that does not exist or a status that node's kind cannot hold.
`--explain` is available on demand ("explain the edges", "what does each edge point at?") and
renders every edge, or only those of the node IDs you name, with its target's first line, so an
edge that resolves cleanly but says the wrong thing is visible to a reader. `--precheck` prints
the `PRECHECK:` block the `next` brief quotes (stale gates, pending and crossed exits, deferred
items, fired triggers, futility, or `precheck: silent`) ahead of the unchanged report; both flags
come before the repo path, and neither changes the exit code.

When the lint reports **error**-severity violations, summarize them and **offer** to fix them; do
not auto-fix. On the user's approval, repair through the normal reconcile behavior:

- invalidation inconsistency: mark the un-blocked downstream node `blocked`, and trace further
  downstream as a reconcile would.
- dangling edge: ask the user which node was meant and re-point the edge, or remove it if they
  confirm it should be dropped. Do not silently delete an edge; the intended target is not
  recoverable from the graph alone.
- unreadable edge: rewrite it in the flat one-line form (`- {rel: <relation>, to: <target>}`).
- invalid `status` or `kind`: correct it to a valid value from the node model.
- missing provenance path: ask the user which artifact was meant and re-point it, or remove the
  entry if they confirm it; do not guess a path. A git-ignored path is only a warning; leave it
  unless the user would rather cite a tracked artifact.
- mutual pair (`invalidated_by`, `supersedes`, or `part_of` running both ways between two nodes):
  ask the user which direction is true and remove the reversed edge, never both; direction is the
  claim, and the graph alone cannot tell you which way it goes.
- self-loop: remove the edge; a node cannot invalidate, supersede, or belong to itself.
- missing path target (an edge `to:` a repo-relative path that is not on disk): ask the user which
  artifact was meant and re-point it, or remove it if they confirm; do not guess a path.

The pre-check's lines are findings to raise, not errors to repair, and each is a proposal:

- fired trigger (`FIRED`): propose reopening the deferred item, per the reconcile section.
- pending exit (`EXIT_PENDING`): propose the comparison at reconcile, where the result is weighed
  against the exit and `exit_outcome` is offered as its own yes or no.
- stale gate (`STALE_GATE`): read the gate text; when the named node's finish actually met the
  gate, propose a gate rewrite (or the stage transition it earns). Approval-gated, and never
  applied by `next`; a gate that cites a finished run only as a baseline is not stale.

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
reasons; open ideas; a section headed "Deferred, reopen when" listing each `deferred` idea or
experiment with its `reopen_when` trigger (or "no trigger"), omitted when nothing is deferred.
One screen. Regenerate it; do not maintain it by hand (a maintained summary drifts).

### The graph visualization (a mermaid diagram of the actual nodes)

`status.md` opens with a `mermaid` flowchart built from the real `graph/` — the visual
interface to the graph itself. Build it by reading the same frontmatter the text sections read:

- **One node per graph node.** Label it `<ID>\n<short title>`. Shape/style by kind + status:
  - `pipeline_node` `validated` → solid box; `assumed_working` → box, dotted border;
    `untested` → box; `invalidated` → **red fill**; `blocked` → **orange/dashed**.
  - `theory` → rounded (stadium) node, append its lifecycle stage (e.g. `(backtest)`).
  - `experiment` / `decision` / `idea` / `observation` → default nodes; keep them present but
    visually quieter than theories and pipeline nodes.
  - `deferred` (idea or experiment) → muted grey, dashed border, distinct from blocked's orange
    dashed and invalidated's red: `classDef deferred fill:#f0f0f0,stroke:#999,stroke-dasharray:
    4 4,color:#666` and one `class <IDs> deferred` line naming every deferred node.
  - Apply mermaid `classDef` + `class` for the invalidated/blocked/validated/deferred styles so
    the states read at a glance; keep the palette to a few classes, not per-node styling.
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

## Calibrate (on demand)

`/tendrel:calibrate` (and natural language: "are my numbers checkable?", "calibrate the graph",
"could tendrel verify the figures in this graph?") runs the read-only `graph-calibrate.sh` over
`graph/` and prints a
measurement report: how many nodes assert precise numbers (two or more decimal places), how many
declare `provenance:`, which cited artifacts resolve, and, for the nodes whose artifacts can be
found, how often a node's numbers appear in them and how often they appear in an *unrelated*
artifact by coincidence (the null test). It answers one question before anyone builds a
number-checking gate for a graph: would such a check be trustworthy here? On the graph tendrel was
calibrated against, a two-decimal figure matched an unrelated artifact 40.9% of the time, which is
why the lint checks that provenance resolves and does not check the numbers themselves.

Run it as `bash "${CLAUDE_PLUGIN_ROOT}/scripts/graph-calibrate.sh"` (if the variable is unset,
locate the plugin's `scripts/graph-calibrate.sh`; it takes the repo root as its argument). Relay
the report honoring `verbosity`, explaining the headline figures in plain language (the command
file names the exact lines to read; section 4 prints *unmatched* counts, so never relay one as a
found count), and offer nothing to fix: it writes nothing and there is nothing to repair. If the user wants tendrel's
maintainers to learn how a different kind of graph behaves, the friction log is the place to note
the summary.

## Planning forward (next, on demand)

`/tendrel:next` (and natural language: "what should we run next?", "where does this stand and what
next?") turns the whole graph into a forward plan. Where `status.md` is a snapshot of state, this is
a synthesis of *history into next steps*. It is read-only: it proposes, it never writes `graph/`.

1. **Lint first, with the pre-check.** Run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/graph-lint.sh" --precheck .` from the repo root (if that
   variable is unset, locate the plugin's `scripts/graph-lint.sh`; the flag comes first, the repo
   root after it). The `PRECHECK:` block prints before the lint report: one line per stale gate
   (`STALE_GATE`), pending or crossed exit (`EXIT_PENDING`, `EXIT_CROSSED`), deferred item
   (`DEFERRED`), fired reopen trigger (`FIRED`), and either `FUTILITY`, `JUDGMENT`, or a literal
   `precheck: silent`; `GATE_CONTEXT` lines are context, never findings. It enumerates and never
   judges: whether a gate that names a finished node has actually been met, or a result crossed
   its exit, is your call from the quoted lines, made in plain language above the footer.
   On error-severity violations, summarize them and offer repair per the Graph lint section before
   trusting a plan; do not silently plan on a graph that fails integrity. If the user asks to proceed
   anyway, plan with a prominent caveat naming the integrity problems that may skew the analysis.
   This pre-empts the verdict the way it pre-empts planning; the pre-check block still prints and
   is still quoted in the footer. Warnings do not block planning.
2. **Read the whole graph**, not just the anomaly summary. Reconstruct the investigation arc.
3. **Produce a brief, then proposals**, in this order:
   - **Brief:** what is validated and what it rests on; what was invalidated and what that ruled
     out; open theories and their `next_gate`; ideas that were `spawned` but never pursued. Group
     it by the actual arc of the work, not by node kind.
   - **Proposals:** 2-3 concrete next experiments. Each names *why now* and *what to skip and why*.
     The negative grounding ("skip X, you already ruled it out in ...") is required, not optional:
     it is the half of the advice a fresh model cannot give and the reader would otherwise waste
     weeks rediscovering. Each proposal also states the losing outcome that would end its line (a
     number or a result agreed before the run), so the exit exists before the experiment does.
4. **The verdict.** The brief ends in exactly one of three verdicts, on exactly one body line that
   reads `Verdict: continue`, `Verdict: conclude`, or `Verdict: wait`. Markdown emphasis or a
   heading around it is fine (`**Verdict:** continue`, `## Verdict: continue`); the detectors strip
   leading markup. Never emit two such lines. What follows depends on the verdict:
   - **continue:** the 2-3 proposals from step 3, each with its losing outcome.
   - **conclude:** what stands, what it rests on, and what would reopen the line. No proposals.
   - **wait:** what unlocks the work, listing every trigger. No proposals.

   Choose it in this order. If the pre-check printed `FUTILITY`, the verdict is `wait` with no
   judgment: everything open is deferred behind a node-form trigger that has not fired, and the
   wait section lists every trigger. If nothing at all is open or deferred (no open idea, no
   planned or running experiment, no deferred item), the verdict is `conclude` or `continue`,
   never `wait`. Otherwise judge, under a burden of proof: a `continue` rests on at least one
   non-terminal node whose next result would change what the graph says (a planned or running
   experiment, an open idea, or a theory with an unmet gate); complete, abandoned, invalidated,
   dropped, and shelved nodes cannot discriminate and do not count. A `conclude` or `wait` rests
   on the nodes whose evidence settles the line or whose triggers gate it; cite those settling
   nodes, not the ones you are declining to run. A `JUDGMENT` line means a deferred trigger is
   text, missing (listed as `(no trigger)`), or can never fire as written (it names a node that
   does not exist, or a status that node's kind cannot hold); read it yourself and say what you
   decided.

   Two evidence rules: a null result with no `bound` in its frontmatter is uninformative, so never
   cite it to conclude a line or to refute anything (it excludes no effect size); a `validates`
   edge from an experiment with no `compared_to` is provisional support, and the brief says so.
   Take the second list from the lint's warning rather than re-deriving it; the first is a
   frontmatter read. Whether a result is a null stays a judgment.

   Deferred items go under a heading "Waiting on", each with its trigger in plain language. Never
   propose a deferred item unless the pre-check printed `FIRED` for it or, for a text trigger, you
   argue that the trigger fired and cite the evidence in the footer.

   A verdict is advice, never drift: `next` writes nothing to `graph/` under every `reconcile`
   value, and no status transition follows from a verdict without the user's say. A stale gate, a
   crossed exit, and a fired trigger are reported here and proposed at reconcile.

**Human-readable is the contract, not a nice-to-have.** Write it the way a colleague would brief
you. Name the real things in plain language (the reflexion cascade, the local labeling run, the
disease-NER gate), and put **no node IDs in the brief or the proposals**. A body that reads like a
list of `EXP-0NN` references has failed, even though the IDs are technically "citations." The IDs
are your internal grounding, they keep you honest, you may not propose a step the evidence does not
support, but they are invisible to the reader.

**The trace footer is the only place IDs appear.** End with a single, skippable section headed
exactly "Where this came from" that maps the claims and proposals back to the node IDs behind them,
for a reader who wants to verify a surprising claim. Cite only nodes that exist; never invent an ID.
Everything above the footer must stand on its own without it. The footer carries two pinned lines:
`Pre-check:` followed by the `PRECHECK:` block verbatim (from its `PRECHECK:` line through the last
finding or `precheck: silent`), and then `Verdict rests on:` followed by the node IDs the verdict
rests on under the burden of proof above. The quoted block runs from the `Pre-check:` line to the
`Verdict rests on:` line, inside a fenced code block if you prefer, so put nothing else between
them. A `Verdict rests on:` line with no real node ID is a missing verdict. Any evidence that a
text trigger fired is cited here too.

Honor `verbosity`: `succinct` trims the brief toward the arc summary and keeps the verdict, the
proposals or the triggers, and the footer; `off` still answers when asked directly (this is
on-demand, not an automatic surface) and keeps the `Verdict:` line and the footer. Works
in any tendrel repo with no other plugins installed. If there is no `graph/`, or it exists but has
no nodes yet, the repo isn't scaffolded for planning; offer to scaffold or point to `/tendrel:seed`
rather than planning from nothing (there is no history to synthesize).
