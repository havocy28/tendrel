# Changelog

All notable changes to tendrel. Versions follow semver. The self-hosted marketplace serves the
default branch, so the latest tagged version is what installs pull on `/plugin marketplace update`.

## 0.9.0 - 2026-09-04

### Added
- **Edges mean what they say.** `invalidated_by`, `supersedes`, and `part_of` carry their whole
  meaning in their direction, so the lint now errors on a pair of nodes that each claim the other
  with the same relation, and on a node that points at itself. Pairwise and deterministic, with no
  false-positive surface: two different relations in opposite directions are fine. This is the
  check that would have caught a reversed `invalidated_by` pair a user shipped under
  `reconcile = auto` in 0.7.0, and it catches three such pairs on the maintainer's own 111-node
  graph on the day it lands.
- **Repo-relative edge targets.** An edge `to:` may name a node or any repo-relative path (a
  `wiki/` page, the plan document that motivated a node, a results file). Paths are validated the
  way `provenance:` paths are: tracked and present is silent, present but untracked warns, matched
  by the repo `.gitignore` is silent whether or not it exists, missing is an error naming both
  readings (no node with this ID and no such file). The permanent "unrecognized edge target"
  warning is gone; a link to a private plan document no longer trains readers to skip warnings.
- **`graph-lint.sh --explain`.** Prints each edge as `SRC rel TARGET "first line of the target"`
  before the normal report, optionally scoped to node IDs, with the report and exit code unchanged.
  A wrong target is obvious on sight. `/tendrel:lint` runs it on request ("explain the edges").
- **Write-moment review in the skill.** Before the first edge to a target in a sweep, the agent
  reads the target's first body line; after writing edges, it runs `--explain` on the touched nodes
  and reviews each rendered line before the sweep ends, under `ask` and `auto` alike and never as a
  prompt. Both sentences are pinned by `test/checks.sh`, and `test/edge-review-integration.sh`
  measures them headlessly against a fixture whose decoy node shares the prompt's vocabulary while
  its first line states the opposite claim, so only reading distinguishes the right target.
  Measured 2026-09-04, N=5: wrote the graph 5/5, linked the intended experiment and not the
  decoy 5/5, produced no reversed pair 5/5, ran `--explain` before finishing 5/5.

### Fixed
- The showcase graph (`examples/doc-search`) carried reciprocal `part_of` edges from its theories
  back to their experiments, the exact shape the new check rejects; the rendered diagram never
  showed them, and the data now matches it.

### Compatibility
- Additive in every surface except the lint's verdict on graphs that were already wrong. Newly
  failing patterns: a reversed same-relation pair or a self-loop on `invalidated_by`,
  `supersedes`, or `part_of` (3 of 111 nodes on the maintainer's genetics graph carry one); an edge
  whose target is a path that does not exist and is not ignored (previously a permanent warning);
  a node ID that strays from `PREFIX-NNN` is still a node target when the node exists, so odd IDs
  do not start failing. Ignored path targets go silent. Every existing invocation of the lint is
  byte-identical, pinned by a fixture. The backwards-compat sweep passes on the examples and the
  compat graphs.

## 0.8.0 - 2026-09-01

### Added
- **Provenance in the node model.** Any node can declare `provenance:`, a flat list of repo-relative
  paths naming the artifacts its numbers come from (`provenance: [results/exp-012-ner.md]`). The
  lint checks that every declared path resolves: a missing path is an error, a git-ignored path
  (`raw/`, `work/`) is a warning because it vanishes from a clean checkout, and an absent key is
  silent, so graphs that never declare provenance are untouched.
- **Numbers come from artifacts, not transcription.** The skill's logging section and reconcile
  sweep now say: when recording a number, read it out of the artifact that produced it and name
  that artifact in `provenance:`. This is the highest-value change in the release and it is not a
  command. The motivating failure was a node quoting `p=0.94` while its results file held
  `0.9487862`; that is a transcription error, and prevention beats detection. `test/checks.sh`
  pins the sentence; `test/provenance-integration.sh` measures it headlessly (opt-in tier).
  Measured 2026-09-01, N=5: wrote the node 5/5, declared provenance 5/5, recorded the
  artifact's precise figure rather than the rounded one narrated in chat 5/5.
- **Calibrate (`/tendrel:calibrate`).** A read-only report on how checkable a graph's numbers are
  against the artifacts they cite: nodes asserting precise figures, nodes declaring provenance,
  how often a figure is found in its cited artifact, and how often it would match an unrelated
  artifact by coincidence (the null test). On the 107-node graph it was calibrated against, a
  two-decimal figure matched an unrelated artifact 40.9% of the time, which is why tendrel checks
  that provenance resolves and deliberately does not check the numbers themselves. Covered by 52
  known-answer fixtures in the deterministic test tier.

### Fixed
- `test/checks.sh` scanned gitignored `docs/plans/` for em dashes, so the gate was red only on
  developer machines holding a plan and green in CI. It now scans tracked docs only.
- The friction-log path noted in the skill pointed at a legacy local-install namespace; a
  marketplace install writes to `plugins/data/tendrel-tendrel/FRICTION.md`.

### Compatibility
- Fully backwards compatible and additive. A new optional frontmatter key, one new lint check that
  is silent when the key is absent, one new read-only command, and skill wording that changes how
  numbers are written, never whether anything writes. The backwards-compat sweep and every
  existing fixture pass unchanged.

## 0.7.0 - 2026-07-17

### Added
- **Forward planning (`/tendrel:next`).** The counterpart to `status.md`: where status is a
  snapshot of state, this synthesizes history into next steps. It lints the graph, reads the whole
  history, and returns a plain-language state-of-the-investigation brief plus 2-3 grounded
  next-experiment proposals, each with why-now and what-to-skip (the paths you already ruled out,
  the half of the advice a fresh model cannot give). Read-only: it proposes and writes nothing;
  output goes to the transcript, not a file, because it is advice, not state.
- **Human-readable contract, enforced.** The brief and proposals name things in plain language and
  carry no node IDs; the IDs are internal grounding surfaced only in a single skippable "Where this
  came from" trace footer. `test/checks.sh` guards the contract's load-bearing rule against silent
  edits, and an on-demand harness (`test/next-integration.sh`) measures the two hard rules on real
  output: the body is ID-free, and every footer citation resolves to a real node.

### Compatibility
- Fully backwards compatible and additive. A new skill section, one new command, docs, and one
  on-demand test; no behavior changes for anyone who does not invoke `/tendrel:next`.

## 0.6.0 - 2026-07-13

### Added
- **Configurable reconcile autonomy.** A third optional `.research-graph` key,
  `reconcile = ask | auto` (default `ask`). `ask` is the behavior tendrel has always had: offer to
  reconcile when the graph looks behind, write only on approval. `auto` is a per-repo opt-out of
  the write gate: at natural pauses (a result lands, a task completes, session open with drift)
  the agent folds work into `graph/` without asking, then runs the deterministic graph lint on
  what it wrote and reports the result, so unattended writes still get a non-model integrity
  check. Explicit `/tendrel:reconcile` behaves identically under both values. Orthogonal to
  `background` (which controls where output lands, not whether reconcile asks).
- **Autonomy-aware SessionStart report.** Under `reconcile = auto`, the report's footer switches
  from the on-demand nudge to an explicit instruction to fold drift in without asking. The hook is
  the one carrier that does not depend on skill activation, so it, not the skill text, is what
  makes session-open pickup dependable in real sessions. With no key (or `ask`) the report output
  is byte-identical to 0.5.0.
- **Contract measurement** (`test/reconcile-autonomy-integration.sh`): a headless N-run harness
  asserting the safety invariant (no `reconcile` key or `ask` means zero unattended sweep writes,
  hard fail) and measuring the `auto` trigger rate. Measured at introduction: the ask/no-key gate
  held at 0/3 on a disk-drift prompt; `auto` folded narrated results in at 3/3 and discovered
  disk drift at 1/3 and 2/5 (a floor: headless `claude -p` runs do not fire SessionStart hooks,
  so the harness cannot see the hook-carried path that covers session open in real use).

### Compatibility
- Fully backwards compatible and additive. With no `reconcile` key, behavior is byte-identical to
  0.5.0: the default-path gate in the skill is asserted by `test/checks.sh`, the report's default
  output is covered by `test/report-verbosity.sh`, and the no-key path was measured against the
  0.5.0 baseline directly (identical 2/3 live-logging rate on a result-narrating prompt, before
  and after; live logging of narrated work is long-standing behavior and is not what this key
  gates).

## 0.5.0 - 2026-07-08

### Added
- **Deterministic graph lint.** A read-only `plugin/scripts/graph-lint.sh` checks `graph/` for
  dangling edges (a node-ID or `wiki/` reference that does not exist), invalid `kind`/`status`
  values, duplicate IDs, `depends_on` cycles, and invalidation-consistency. The consistency rule
  is transitive: a node that `depends_on` an `invalidated` (or already-`blocked`) node must itself
  be `blocked`, so invalidation must propagate all the way down a chain, not just one hop. It exits
  non-zero on errors and never writes to `graph/`, so it is safe as a CI gate.
- **`/tendrel:lint` command** (plus *"lint the graph"*). Runs the script, reports its findings
  honoring `verbosity`, and on error-severity violations offers approval-gated repair through the
  normal reconcile behavior. Detection is deterministic (the script); repair stays with the model
  and only writes after you approve. After an approved repair, the lint is re-run so the
  deterministic check confirms the fix held.
- **Robust edge parsing.** Edge reading tolerates harmless variation (extra spaces around colons,
  extra keys after `to:`), so a well-formed edge is never skipped. An edge that genuinely cannot be
  read on one line (for example, block-style YAML split across lines) now fails closed with a
  plain-English error naming the file and the correct shape, rather than being silently dropped and
  letting an inconsistent graph lint clean. Reconcile also rewrites edges in the flat form when it
  touches a node, so off-format edges heal in normal use.
- **No crash on deep graphs.** Cycle detection is iterative, so a very deep `depends_on` chain
  reports cleanly instead of raising a `RecursionError`.
- **Test coverage** (`test/graph-lint.sh`): 23 fixture scenarios, including multi-hop transitive
  invalidation, tolerant-parse cases (a stray space and a trailing field, both formerly silent
  false negatives), an unreadable-edge error, a malformed-frontmatter error that does not abort the
  run, a self-loop cycle, and positive controls (a fully-blocked chain lints clean).

### Compatibility
- Fully backwards compatible and additive. The lint is opt-in and read-only; with no invocation,
  behavior is byte-identical to 0.4.0. Nothing changes for existing projects unless they run it.

## 0.4.0 - 2026-07-07

### Added
- **Configurable verbosity.** An optional `verbosity` key in `.research-graph`
  (`succinct | normal | off`, default `normal`) controls how much the SessionStart report and
  command summaries surface. `off` still surfaces confidently-wrong anomalies (dangling edges,
  empty-body nodes) and disables the proactive reconcile offer, since the report is the only
  automatic drift signal.
- **Opt-in background execution for status.** An optional `background` key (`on | off`, default
  `off`) runs `/tendrel:status` in a dispatched subagent, keeping the graph scan out of your main
  transcript. It isolates context, not wall-clock time (the dispatch is synchronous).
- **Automated test suite** (`test/`): static checks, verbosity scenarios, and a headless
  compliance harness (`test/background-integration.sh`) that measures background dispatch rates.

### Notes
- `seed` and `reconcile` run inline. Background seed was measured at 2/10 dispatch (it does the
  read-and-draft inline because the proposal returns to you for approval regardless), and
  reconcile's input is the live conversation a subagent cannot see. Both may be backgrounded in a
  future release once the contract reliably triggers.

### Compatibility
- Fully backwards compatible and additive. With no config keys present, behavior is byte-identical
  to 0.3.0. Nothing changes for existing projects unless they opt in.

## 0.3.0

### Added
- In-session scaffolding via `/tendrel:seed`: it creates `graph/`, `raw/`, `wiki/`, and
  `.research-graph` when a repo is not yet set up, then proposes a starter graph for approval. No
  terminal step required. `setup-research-repo.sh` remains a command-line convenience.

## 0.2.0

### Added
- Slash commands `/tendrel:reconcile`, `/tendrel:status`, `/tendrel:seed`.
- Graph visualization: `status.md` renders a mermaid diagram of the graph.
- Docs (how-it-works, node-model, recipes) and a rendered example under `examples/doc-search`.
