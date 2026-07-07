---
title: Test agent-behavior contracts empirically; fire-and-forget backgrounds, propose-and-approve does not
date: 2026-07-07
type: design-learning
tags: [claude-code, plugin, subagents, background-execution, testing, headless, markdown-contract]
status: resolved
---

# Test agent-behavior contracts empirically; fire-and-forget backgrounds, propose-and-approve does not

## Context

Tendrel's behavior lives in markdown contracts (`plugin/skills/research-graph/SKILL.md`, the command
files) interpreted by the model at runtime, not in deterministic code. Adding opt-in **background
execution** (dispatch a subagent for heavy operations so the file scan stays out of the main
transcript) came with a natural assumption: if the contract says "when `background = on`, dispatch
a subagent for status, seed, and reconcile," the model will comply. A single spot-check (one
`/tendrel:status` run) dispatched a subagent and looked fine.

## Guidance

1. **Measure agent-contract compliance over N runs. Never trust one spot-check.** A markdown
   behavior contract is executed by a probabilistic model, so its effect is a *rate*, not a
   guarantee. Build a headless harness that runs the real contract many times and computes a
   dispatch/compliance rate.
   - Pattern (Claude Code): run
     `claude -p "<prompt>" --output-format stream-json --verbose --dangerously-skip-permissions --plugin-dir <plugin-dir>`
     in a fixture repo, and parse the stream with `jq` for a `tool_use` whose `name` is `Task` or
     `Agent` (a subagent was dispatched) and the length of the final `result` (terse main-thread
     output). Repeat N times, count the rate.
   - Fixtures must match the operation's real input shape. `status` needs a populated graph to
     regenerate from; `seed` needs project content but **no** pre-existing graph (an already-populated
     graph makes seed a no-op and hides its real path). A wrong fixture produces a misleading rate.

2. **Fire-and-forget operations background reliably; propose-and-approve operations do not.**
   Measured with the harness at N=10: `status` (read files, write `status.md`, return "done")
   dispatched **10/10**. `seed` (read the project, draft a proposal the user must review) dispatched
   **2/10**: the model does the read-and-draft inline because the proposal must come back to the user
   anyway, so delegating buys nothing. `reconcile` cannot background at all (its input is the live
   conversation, which a fresh subagent cannot see). Heuristic: **only background work whose result
   the user does not need to see mid-flight.**

3. **Give the harness a real fail path.** A "measure and print" script that always exits 0 is not a
   gate. Assert the must-pass invariants (the default/opt-out path does NOT dispatch; the promoted
   operation DOES) and exit non-zero on violation, so the harness can actually catch a regression.

## Why this matters

Without the N-run harness, the first (`status`) spot-check would have shipped "background your seed
and reconcile too" as a promised feature that works about 20% of the time, which is silent trust
erosion. The measurement turned "background works, I think" into a scoped, honest release:
**background = status only**, with seed and reconcile documented as inline. For a plugin that ships
to every installed project via marketplace HEAD, advertising an unreliable feature is a real cost,
not a cosmetic one.

## When to apply

Any time behavior is defined by a markdown or prose contract executed by the model rather than by
deterministic code: plugin skills, slash-command instructions, subagent-dispatch contracts.
Especially before promoting the behavior in the README, docs, or CHANGELOG.

## Examples

- Harness: `test/background-integration.sh` (headless dispatch-rate measurement, with the
  default-path guard and the per-operation expectations).
- The result that drove the design: `status` 10/10 vs `seed` 2/10, so background was scoped to
  status; seed and reconcile ship inline (v0.4.0).
- Related: [stop-hook-vs-interactive-skills](stop-hook-vs-interactive-skills.md), the same theme:
  agent-runtime behavior needs empirical validation. The Stop-hook mechanism was spike-validated
  before anything was built on it, and its per-turn firing flaw only showed up in real use.
