---
title: Measure a heuristic rule where the answer is known to be no before shipping it
date: 2026-09-01
type: workflow-learning
status: resolved
category: docs/solutions
module: tendrel-verify-calibration
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - designing a heuristic classification or matching rule before shipping it
  - an aggregate metric (precision, unmatched-rate, coverage) points the right way but has not been tested against a known-negative case
  - a check ships with an escape hatch or exemption clause that is itself a heuristic
  - building a measurement harness whose output will be quoted as evidence for a design decision
  - choosing a threshold or cap from distribution shape without testing it near the boundary
symptoms:
  - a heuristic's precision is measured only in aggregate, never against inputs where the correct answer is known to be no
  - a targeted null test recovers matches that reintroduce the original motivating failure
  - an aggregate improvement is explained entirely by a handful of hardcoded literals in a few files
  - a hedge or exemption clause exempts a large fraction of ordinary, non-hedging prose
  - precision measured at one operating point collapses when tested one step away (e.g. cap=1 vs cap=2)
root_cause: >
  Each sub-rule (precision-aware matching, cited-script search, cap-3 file suggestion, the hedge
  exemption) was justified with an aggregate metric that moved the right direction, but aggregate
  metrics do not distinguish a rule that discriminates correctly from one that passes by
  coincidence. None were checked against a negative control: claims tested against artifacts that
  did not produce them. When that null test finally ran, exact-number matching passed 20.7% of the
  time coincidentally (40.9% for two-decimal claims) - well above a usable false-positive rate -
  showing the aggregate signal had never been sufficient evidence on its own.
resolution_type: tooling_addition
related_components:
  - tendrel-verify
  - graph-calibrate
  - provenance-tracking
tags: [heuristic-validation, null-test, measurement, calibration, false-positive, provenance, fixtures, escape-hatch]
---

# Measure a heuristic rule where the answer is known to be no before shipping it

## Context

A `tendrel:verify` design effort ran for three days, from the commit "calibration harness for the
verify design, with known-answer tests" (2026-08-31) to the commits shipping provenance and
`/tendrel:calibrate` (2026-09-01). The goal was
R3: a command checking that a node's precise numbers actually appear in the artifacts it cites. It
was never shipped. Three successive sub-rules were each justified by an aggregate that pointed the
right way, and each was overturned by a targeted measurement:

1. **Precision-aware (rounding) matching** recovered 61 of 137 unmatched claims
   (`plugin/scripts/graph-calibrate.sh:332`, section 9, `rounding-recoverable`). The targeted test
   (section 10, the null test below) showed what that recovery actually admits: a rounding match on
   an artifact the claiming node never declared. In the calibrated graph, `OBS-015`'s `0.94` clears
   by rounding against the `0.938` held in a different node's declared artifact (`OBS-017`'s
   `results/founder/panel_repair.md`, a path in the calibrated graph's own repository, not this
   one); the green result reads as "checked against its source" when
   no declared link between claim and artifact exists, the failure class the feature exists to
   catch.
2. **Searching cited scripts** (not skipping `.py`/`.sh`/etc. as candidate artifacts) moved the
   unmatched rate from 27.3% to 26.5% and clean nodes from 16 to 19
   (`plugin/scripts/graph-calibrate.sh:264`, section 4). Per this session's measurements against
   the 107-node graph the harness was calibrated on, all four extra claim matches those three clean
   nodes bought were parameter literals hardcoded in source (`P0S = [0.01, 0.02, 0.05, 0.10]`), not
   results.
3. **A cap-3 candidate-file suggestion** (name the file a missing-provenance claim probably belongs
   to, when few enough files hold that number) was chosen from distribution shape: most claims land
   in a small candidate set, only 6 of 137 unmatched claims spread across more than 10 files
   (`plugin/scripts/graph-calibrate.sh:332`, section 9, `>10 candidate files (likely coincidental)`).
   Leave-one-out precision, measured directly (`plugin/scripts/graph-calibrate.sh:506`, section 11),
   was 95.2% at a unique holder, 53.5% at two holders, 48.1% at three. Precision collapsed at the
   first step past a unique holder, which the shape argument never asked about.

The test that killed all three at once: test each node's claims against **another** node's
declared artifacts, where a pass is coincidental by construction. Over 513 claims
(`plugin/scripts/graph-calibrate.sh:465`, `rule('10. MATCHING PRECISION -- null test  (passes
against artifacts that did NOT produce the claim)')`): 20.7% pass under exact matching, another
5.3% pass once rounding is added, and two-decimal claims (the graph's dominant precision) pass
40.9% of the time (65 of 159). That bounds what any version of the check could ever assert, on any
graph shaped like this one, independent of how the three sub-rules are tuned. Nothing built on top
of a match rule with that floor was shippable, so nothing was shipped; the report says so instead
(`plugin/scripts/graph-calibrate.sh:1-14`, the file's own header comment).

Two sub-lessons came out of building the measurement itself.

**The harness needed its own known-answer fixtures before its output was quotable.** Per the
harness's own commit record, two fixtures were wrong on the first pass and the harness was right
both times. The failure worth retelling surfaced
that a documented example, `137,215` matching `137215` after thousands-separator normalization,
can never occur: `137,215` is an integer, and the claim regex excludes integers, so it is never
extracted as a claim in the first place (`test/verify-calibration-selftest.sh:199-200`). The
selftest currently holds 56 fixtures, confirmed by running `bash
test/verify-calibration-selftest.sh | tail -1` (read-only; it writes nothing) against the current
tree.

**When a check and its escape hatch are both heuristics, measure the hatch, not just the check.**
The hedge exemption (treat a number as approximate, and skip it, when `approximately`, `about`,
`under`, `over`, etc. sit near it) was first scoped to the whole sentence. That scope exempted 213
of 583 numbers; adjacent-token scope (the marker must be the token immediately before the number)
exempted only 17. The gap between the two, 196 numbers, 33.6% of 583, is nobody who wrote `under
the 0.60 floor` or `averaged over 10 runs` meaning to hedge; `under` and `over` are ordinary prose,
not hedge markers, and trimming the marker list did not close the gap by itself
(`plugin/scripts/graph-calibrate.sh:226-239`, section 2, `rule('2. HEDGE RULE  (when a stated
number counts as approximate)')`, the `--> fail-open gap` line). Scope, not the marker list, was
the whole problem: 45.5% of numbers sat on table or indented lines with no sentence boundary to
compute at all.

What shipped instead of a matching gate: prevent transcription rather than detect it.
`plugin/skills/research-graph/SKILL.md:136-141` now tells the agent, under "Recording a number,"
to read a number out of the artifact that produced it and name that artifact in `provenance:`,
rather than restating it from conversation or memory. `test/checks.sh:62-64` pins that sentence
(`grep -qF 'read the number out of'`) so an edit cannot silently drop it. `test/provenance-
integration.sh` measured the write-side contract headlessly at N=5 (`test/provenance-
integration.sh:20`): wrote the node in 5/5 runs, declared provenance in 5/5, and held the
artifact's precise figure (not the rounded figure narrated in the prompt) in 5/5.
`plugin/scripts/graph-lint.sh:185-209` checks that every declared `provenance:` path resolves on
disk (deterministic, no matching involved). The calibration harness itself shipped as
`plugin/scripts/graph-calibrate.sh` behind `plugin/commands/calibrate.md`, so any graph can produce
the same evidence about itself rather than trusting the one 107-node corpus this was calibrated
against.

## Guidance

1. **Before shipping a rule justified by an aggregate, construct the null.** Run the rule on a case
   where the answer is known to be no, and read the pass rate. An aggregate moving the right
   direction (more matches, more clean nodes, tighter candidate sets) tells you the rule helps; it
   does not tell you how often the rule is right for the wrong reason. Here, testing each node's
   claims against a different node's artifacts, a match that must be coincidental, put a hard
   number (40.9% for two-decimal claims) on what any version of the rule could claim, before a
   single line of the gate shipped.
2. **Give the measurement harness its own known-answer fixtures before quoting any of its
   numbers.** A harness that has not been tested against fixtures with an answer known by
   construction is the same failure it exists to catch, one level up. Here, the fixtures caught two
   wrong assumptions in the harness itself, including one that made a documented worked example
   provably unreachable.
3. **Measure the escape hatch with the same rigor as the check.** A hedge exemption, an ignore
   list, a confidence threshold: these are heuristics too, and a heuristic exemption can fail open
   silently while the check it guards looks fine in isolation. Here the exemption's scope, not its
   marker vocabulary, was leaking a third of all numbers.
4. **When the null rate is high, prefer removing the failure class at the write side over detecting
   it at the read side.** A gate whose passes carry double-digit coincidental noise is worse than no
   gate, because it spends trust on evidence users have no way to discount. Making the number come
   from the artifact in the first place removes the transcription error the check was trying to
   catch, at a fraction of the design cost and with no matching-rule noise to inherit.

## Why This Matters

Each of the three sub-rules would have shipped on its own merits if judged only by its headline
aggregate: more recovered claims, more clean nodes, a plausible-looking cap. None of those numbers
were wrong; each was simply answering a different question than "would this check's passes be
trustworthy." A gate built from all three would have told users a node's numbers were "verified"
at a pass rate that, per the null test, is coincidental correct roughly one time in five for exact
matches and two in five for two-decimal claims, with no way for a user reading a green check mark
to know that. Shipping a check with that ratio of signal to noise is a real cost for a tool whose
whole premise is that agents forget results and experiment state across sessions: a badge that
means less the more artifacts a node cites is worse than no badge. The null test turned three
plausible design choices into one clear non-ship decision, and pointed at the fix that actually
closes the gap (write-side provenance) instead of the fix that looked closest at hand (a better
matching rule).

## When to Apply

- Before shipping any rule, gate, or check whose justification is an aggregate rate moving in the
  right direction (more matches, higher recall, fewer false negatives) with no negative control.
- Any time a check ships with an escape hatch, exemption list, or threshold that is itself decided
  by a heuristic; measure that hatch's false-open rate the same way you measure the check's true-
  positive rate.
- Any measurement harness whose output will be cited in a design document or a shipped report;
  give it known-answer fixtures first, the same way `graph-calibrate.sh` is covered by
  `test/verify-calibration-selftest.sh` before any of its numbers get quoted.
- Especially for fuzzy or fuzzy-adjacent matching over free text (number matching, string
  similarity, keyword triggers): construct the case where a match is coincidental by definition and
  read the pass rate before trusting the aggregate.

## Examples

The null test, from the harness itself:

```
$ grep -n "rule('10" plugin/scripts/graph-calibrate.sh
465:rule('10. MATCHING PRECISION -- null test  (passes against artifacts that did NOT produce the claim)')
```

```
  claims tested against a NON-producing artifact : 513
    pass under exact matching                    :  106   20.7%
    additional pass under precision-aware        :   27    5.3%
    combined coincidental pass rate              :  133   25.9%

  by claim precision (exact / +rounding / total):
    2dp     65  40.9%   ...   of 159
```
(field labels and layout per `plugin/scripts/graph-calibrate.sh:465-503`; the 2dp exact-match value
(65/159, 40.9%) and the totals above are per this session's measurements against the calibrated
graph; the per-precision rounding column is omitted here since this session did not record it)

The suggestion-precision result that killed the cap-3 rule:

```
$ grep -n "rule('11" plugin/scripts/graph-calibrate.sh
506:rule('11. SUGGESTION PRECISION  (would naming the file holding a number name the right file)')
```

```
  cap 1: fires on  ... claims, names  ... files,  ... are a true source  -> precision  95.2%
  cap 2: fires on  ... claims, names  ... files,  ... are a true source  -> precision  53.5%
  cap 3: fires on  ... claims, names  ... files,  ... are a true source  -> precision  48.1%

  --> precision collapses at the first step past a unique holder, not at high fan-out.
```
(line format per `plugin/scripts/graph-calibrate.sh:530-533`; the three precision figures, 95.2%,
53.5%, 48.1%, are per this session's measurements against the calibrated graph; the fired/named/
true-source counts are omitted here since this session did not record them)

What shipped instead of a matching gate, `plugin/skills/research-graph/SKILL.md:136-141`:

```
- **Recording a number** (a `result`, a metric, a count in the body) → read the number out of
  the artifact that produced it (the results file, table, or log on disk) rather than restating
  it from conversation or memory, and name that artifact in `provenance:`. Transcription is where
  drift enters: a node quoting `p=0.94` while its results file holds `0.9487862` is the failure
  this prevents.
```

Pinned so an edit cannot silently drop it, `test/checks.sh:62-64`:

```sh
grep -qF 'read the number out of' plugin/skills/research-graph/SKILL.md \
  && ok "provenance write-side contract present in SKILL.md" \
  || no "provenance write-side contract present in SKILL.md" "the 'read the number out of the artifact' sentence is load-bearing"
```

## Related

- [Baseline before blaming failed measurements](baseline-before-blaming-failed-measurements.md):
  the same lesson at a different scale. That doc is for when a rate-based measurement has already
  failed (baseline against the prior version, re-specify the invariant); this one is for before a
  rule is trusted at all (construct the case where the answer must be no).
- [Test agent-behavior contracts empirically](testing-agent-behavior-contracts.md): how the
  write-side provenance contract that replaced the matching check is itself measured
  (`test/provenance-integration.sh`, N-run rates, hard versus rate-based assertions). An N-run rate
  with real invariants and a non-zero exit can still pass coincidentally; the null test is the
  missing half of that doc's "give the harness a real fail path" rule.
- [Doc-review and code-review catch different defect classes](review-layers-design-vs-implementation-gaps.md):
  the same failure family seen from the review side: a trust-certifying tool that looks like it
  checks something and does not, on inputs its designers never tried.
