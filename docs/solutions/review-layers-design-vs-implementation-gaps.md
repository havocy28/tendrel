---
title: Doc-review and code-review catch different defect classes; run both on non-trivial work
date: 2026-07-08
type: workflow-learning
tags: [compound-engineering, ce-doc-review, ce-code-review, review, verification, graph-lint, false-negative]
status: resolved
---

# Doc-review and code-review catch different defect classes; run both on non-trivial work

## Context

The graph-lint feature (`plugin/scripts/graph-lint.sh`, `/tendrel:lint`) went through two separate
review passes: `ce-doc-review` on the plan before implementation, and `ce-code-review` on the
shipped branch after. It was tempting to treat the second as redundant, since the plan had already
been reviewed by a five-persona panel and the work matched it closely. Running both anyway showed
they catch structurally different classes of defect, and skipping either would have shipped real
bugs in the one feature whose entire job is to certify the graph is trustworthy.

## Guidance

On non-trivial work, run a plan/document review **and** a code review. They are complementary, not
redundant, because they read different artifacts:

- **Doc-review reasons about the plan.** It catches design and specification gaps: a decision that
  is under-specified, a success criterion that oversells what the design delivers, a scope boundary
  that contradicts a goal. These live in the plan's prose.
- **Code-review reads the implementation.** It catches gaps that exist only in the code and are
  invisible in any plan: a parser that fails open on an input the plan never enumerated, a
  recursive function that crashes on deep input, a regex that silently drops a case. No amount of
  plan-reading surfaces these, because they are not decisions, they are how the decisions got
  typed out.

A useful heuristic: doc-review finds "we designed the wrong thing," code-review finds "we built the
designed thing wrong." Both failure modes are common and neither review sees the other's class.

A secondary lesson from the same episode: when a reviewer proposes a fix, treat the proposal as
input, not a verdict. The code-review panel's instinct for the edge-parsing bug was "fail louder."
The better fix, surfaced by pushing on what a *user* would actually experience, was "parse the
common variations correctly so the error rarely fires, and when it does, say it in plain language
and heal it during normal reconcile." Same finding, a much better resolution, because the finding
was run through a user-experience lens instead of applied verbatim.

## Why This Matters

For graph-lint the split was concrete and load-bearing:

- **Doc-review (on the plan) found a design gap.** The invalidation-consistency check was specified
  as one-hop (a node that `depends_on` an `invalidated` node must be `blocked`), while the plan's
  headline promised that "everything that depends on it" is verified. A chain where invalidation
  propagated only one level would have passed the check while still being inconsistent with the
  pitch. This is a spec-vs-goal mismatch, exactly what a plan review is positioned to see. Fix: make
  the rule transitive (fire on a dependency that is `invalidated` *or already* `blocked`, which
  cascades in a single pass).

- **Code-review (on the shipped code) found implementation gaps the plan could not contain.** The
  adversarial reviewer reproduced two false negatives against live fixtures: an edge with a stray
  space (`rel :`) or a trailing field (`{rel: depends_on, to: NODE-9, weight: 1}`) was silently
  dropped by the edge-parsing regex, so a dangling or unblocked-invalidated edge written that way
  linted clean, exit 0. It also found a recursive cycle-detector that crashed with `RecursionError`
  on a deep dependency chain. None of these are in the plan; they only exist in the regex and the
  recursion. A plan review structurally cannot find them.

Both false negatives were in the exact behavior the feature exists to guarantee. Skipping the code
review because "the plan was already reviewed" would have shipped a trust tool that fails silently
on the cases that matter most.

## When to Apply

- Any feature with real logic (parsers, state machines, traversal, invalidation, anything with edge
  cases), especially one whose value proposition is correctness or trustworthiness.
- When you catch yourself thinking a review is redundant because an earlier review of a *different
  artifact* already passed. Different artifact, different defect class.
- Not worth the ceremony for trivial or purely mechanical changes (renames, config, copy edits).

## Examples

Sequence that worked here:

1. `/ce-plan` produced the graph-lint plan.
2. `/ce-doc-review` on the plan -> found the one-hop-vs-transitive design gap -> fixed the spec and
   the check before more code was written.
3. Implemented and shipped to the branch.
4. `/ce-code-review` on the branch -> adversarial persona reproduced two edge-parser false negatives
   and a recursion crash -> fixed with a tolerant parser plus a plain-English fail-closed error and
   reconcile-time self-healing.
5. Re-ran the suites (16 -> 23 fixtures), verdict moved from "Not ready" to "Ready."

Related learnings:

- [[testing-agent-behavior-contracts]] (`docs/solutions/testing-agent-behavior-contracts.md`): the
  same detect-deterministically / reason-with-the-model split, and the rule that markdown behavior
  contracts must be measured over N runs rather than assumed. Graph-lint's detection is the
  deterministic half; its repair is the model half.
- [[stop-hook-vs-interactive-skills]] (`docs/solutions/stop-hook-vs-interactive-skills.md`):
  `/tendrel:lint` and its approval-gated repair are on-demand, the shape that learning endorses;
  do not move the lint onto a Stop hook.
