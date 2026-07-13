---
title: When a safety measurement fails, baseline before blaming; specify invariants against the gated behavior
date: 2026-07-13
type: workflow-learning
tags: [testing, measurement, baseline, safety-invariant, contract, reconcile-autonomy, fail-closed]
status: resolved
---

# When a safety measurement fails, baseline before blaming; specify invariants against the gated behavior

## Context

The reconcile-autonomy feature (`reconcile = ask | auto`, v0.6.0) shipped with a headless N-run
harness asserting a hard safety invariant: with no `reconcile` key, zero unattended graph writes.
The first measurement failed it: the no-key arm wrote unattended in 2/3 runs, on a gate that ships
to every installed project. The obvious reading was "the new contract broke the default path."
The obvious reading was wrong, and acting on it directly would have produced a worse outcome than
the failure itself.

## Guidance

Three moves, in order, when a rate-based safety measurement fails:

1. **Baseline before blaming.** Run the identical experiment (same fixture, same prompt, same N)
   against the prior version, with none of the new changes present. If the baseline shows the same
   rate, the behavior is pre-existing and the failure is in the measurement's specification, not
   the code. Here: 0.5.0 with no key also wrote in 2/3 runs, an exact match, settling in three
   runs what speculation could not.

2. **Specify the invariant against what the feature actually gates, not against all observable
   behavior.** "Zero graph writes" conflated two behaviors: live logging of work the user narrates
   (deliberate, long-standing, ungated) and the unprompted sweep (the thing the new key gates).
   The honest invariant was "zero unprompted sweep writes," which requires an experiment where
   nothing is narratable: drift on disk only (a notes file ahead of the graph) and an
   information-free prompt. Under the re-specified experiment the gate held at 0/3. A useful test
   for this conflation: if the invariant would have failed on the previous version too, it is not
   describing the feature under test.

3. **When strengthening the contract does not move the rate, suspect the carrier, not the
   wording.** The auto arm's disk-drift pickup stayed at ~1/3 across a skill-text strengthening
   iteration. The cause was not weak wording: headless `claude -p` never fires SessionStart hooks,
   and on a generic prompt the skill may not activate at all, so the strengthened text was not in
   context to be followed. The fix moved the instruction into the hook (the carrier that fires
   unconditionally in real sessions) rather than iterating on prose the model never saw.

One adjacent rule from the same feature's code review, worth keeping attached: **safety-relevant
config keys fail closed.** A user disabling autonomy guessed `reconcile = off` (natural, since
`off` is valid for `verbosity`); last-wins parsing that ignores unrecognized values would have
kept `auto` active after an explicit disable attempt. Any explicit value other than the opt-in
value must mean the safe state, and a deterministic fixture should pin that.

## Why This Matters

Both naive responses to the failed measurement were worse than the failure. Treating it as a
regression would have blocked a compat-clean feature (and "fixing" it would have broken live
logging, a designed behavior users rely on). Shipping anyway on the theory that the test was
"probably wrong" would have left the real question (does the gate hold?) unanswered. The baseline
plus re-specification answered it properly: gate holds at 0/3, live logging identical to 0.5.0,
and the investigation surfaced a genuinely new platform fact (headless runs never see hook
context) that reshaped the feature's delivery mechanism.

## When to Apply

- Any failed rate-based measurement of model or contract behavior, especially safety invariants.
- Any invariant phrased as "zero X" where X could include pre-existing designed behavior; run the
  would-it-fail-on-the-old-version test before trusting it.
- Any contract iteration where reworded instructions do not move a measured rate; check whether
  the instructions are reaching the model at all before strengthening them again.

## Examples

The reconcile-autonomy sequence, compressed:

1. First harness run: auto 3/3 (feature fires), no-key 2/3 (safety "violated").
2. Baseline against 0.5.0, same experiment: no-key 2/3. Identical, so pre-existing (live logging),
   not a regression.
3. Re-specified experiment (disk drift only, nothing narratable): no-key 0/3, gate holds; auto
   1/3, weak.
4. Contract strengthening did not move auto's rate; probe revealed `claude -p` fires no
   SessionStart hooks, so the harness measures a floor and the hook is the real carrier; the
   instruction moved into the report script, validated deterministically by piping synthetic
   payloads (`test/report-verbosity.sh`, 14 to 23 assertions).
5. Code review then reproduced the fail-open disable (`reconcile = off` ignored); parsing made
   fail-closed with a byte-identity fixture for invalid values.

Related learnings:

- [[testing-agent-behavior-contracts]] (`docs/solutions/testing-agent-behavior-contracts.md`):
  how to run these measurements (N runs, rates, real fail paths) and the headless-hooks finding.
  This doc is the companion: how to interpret them when they fail.
- [[review-layers-design-vs-implementation-gaps]]
  (`docs/solutions/review-layers-design-vs-implementation-gaps.md`): the fail-closed disable bug
  was a code-review catch on a surface the measurement could not see, the same
  different-layers-catch-different-defects pattern.
