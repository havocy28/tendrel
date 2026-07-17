# Changelog

All notable changes to tendrel. Versions follow semver. The self-hosted marketplace serves the
default branch, so the latest tagged version is what installs pull on `/plugin marketplace update`.

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
