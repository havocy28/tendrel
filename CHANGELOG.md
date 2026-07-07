# Changelog

All notable changes to tendrel. Versions follow semver. The self-hosted marketplace serves the
default branch, so the latest tagged version is what installs pull on `/plugin marketplace update`.

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
