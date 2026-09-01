---
title: A gate must read the same in every environment it runs in
date: 2026-09-01
type: workflow-learning
status: resolved
category: docs/solutions
module: tendrel-lint-and-gates
problem_type: convention
component: testing_framework
severity: high
applies_when:
  - writing a lint, CI check, or test gate that consults the filesystem or git state
  - a check consults anything git does not commit (ignore rules, untracked files, tool config)
  - a gate is green on one machine and red on another with the same commit
  - reviewing a change to an existing gate for environment dependence
tags: [gates, ci, lint, gitignore, untracked, environment, false-negative, false-positive]
---

# A gate must read the same in every environment it runs in

## Context

The 0.8.0 release of tendrel added a provenance check to `plugin/scripts/graph-lint.sh` (every
`provenance:` path a node declares must resolve) and changed `test/checks.sh` to stop scanning
gitignored working material for em dashes. Both changes applied one principle: a gate that is red
on exactly one machine is a gate people learn to ignore, which is worse than no gate. The code
review of the same release then found the principle violated three ways in the same diff, each one
reproduced by the validator in a scratch checkout:

- A provenance file that existed on disk but was never committed linted clean on the developer
  tree and errored with "does not exist" in a fresh clone of the same commit.
- A missing path matched by a per-machine ignore rule (`core.excludesFile` or `.git/info/exclude`)
  was a warning locally and an error in CI, because `git check-ignore` honours every ignore source
  and only the repo's own `.gitignore` travels with the commit.
- The em-dash scan, switched to `git ls-files` to skip gitignored plans, now skipped a new doc
  written in the session too: green before the commit, red after it landed.

Each violation had the same shape: the gate consulted state that git does not carry in the commit,
so its verdict depended on which machine ran it.

## Guidance

1. **Enumerate the environments the gate runs in** before writing it: the developer's working
   tree, a fresh clone, CI, and a git-less export (archive, container copy). A gate is finished
   when its verdict is the same in all of them for the same commit.
2. **Sort every input the gate reads into committed state and machine state.** Committed: tracked
   files, the repo's `.gitignore`, the commit itself. Machine state: untracked files, ignored
   files, global and per-repo ignore rules, tool configuration, environment variables. Only
   committed state may change a pass into a fail.
3. **Machine state may warn, identically everywhere, or be ignored; it may never flip the
   verdict.** `graph-lint.sh` reads the ignore source `git check-ignore -v` names and counts only
   a repo `.gitignore` (`plugin/scripts/graph-lint.sh:85-106`); a path that exists but is untracked is a warning that
   reads the same on every machine, since a clone will not have it (`plugin/scripts/graph-lint.sh:185-210`).
4. **Scan tracked plus untracked-but-not-ignored when the gate is about content the author is
   about to commit.** `test/checks.sh` uses `git ls-files --cached --others --exclude-standard`
   (`test/checks.sh:83`), so a doc written this session is caught before it lands in CI, while
   gitignored working material stays out.
5. **Prove it with a fixture that runs the gate from the other side.** The lint tests hold one
   fixture with a repo `.gitignore` (`test/graph-lint.sh:405`) and one that commits one file, leaves another
   untracked, and sets a per-machine `core.excludesFile` (`test/graph-lint.sh:427`); the expected verdicts are
   the ones a clean checkout would produce.

## Why This Matters

A gate exists to be trusted without thought. The moment its colour depends on the machine, every
red becomes "probably just my setup" and every green becomes "probably fine here", and the gate
stops carrying information in the one place it was meant to: the decision to merge. The three
violations above were each small and each independently plausible, which is the point: nobody
writes an environment-dependent gate on purpose. The check is mechanical (which inputs are
committed?) and cheap to run at review time, and it caught three defects in a release whose whole
premise was environment independence.

## When to Apply

- Writing or changing any lint, test gate, or CI step that reads the filesystem or asks git a
  question.
- Reviewing a diff that adds `git check-ignore`, `git ls-files`, `os.path.exists`, or a directory
  walk to a gate.
- Diagnosing "passes locally, fails in CI" or its quieter twin, "fails locally, passes in CI".

## Examples

Before (verdict depends on the machine):

```python
elif git_ignored(p):            # honours core.excludesFile and .git/info/exclude
    warnings.append(...)
elif not os.path.exists(...):   # an untracked file passes here, fails in every clone
    errors.append(...)
```

After (`plugin/scripts/graph-lint.sh:185-210`): the ignore source must be a repo `.gitignore`; a present-but-untracked
path warns; a missing path errors, the same everywhere.

Before (`test/checks.sh`): `git ls-files -- 'docs/*.md'` skips a new untracked doc, so the
em-dash gate is green until the commit lands. After (`test/checks.sh:83`): `--cached --others
--exclude-standard` scans what is about to be committed and nothing that is ignored.

## Related

- [Doc-review and code-review catch different defect classes](review-layers-design-vs-implementation-gaps.md):
  the review layer that caught all three violations here, in the same script it caught the edge
  parser's false negatives in.
- [Measure a heuristic rule where the answer is known to be no before shipping it](null-test-heuristics-before-shipping.md):
  the companion learning from the same release, about the other way a gate misleads: passing for
  the wrong reason.
