#!/usr/bin/env bash
# Tier-1 deterministic test for U1 (graph-lint). No model needed.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$REPO/plugin/scripts/graph-lint.sh"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  $2"; fail=$((fail+1)); }
newfix(){ local d; d="$(mktemp -d)"; mkdir -p "$d/graph"; echo "$d"; }
node(){ printf '%s\n' "$3" > "$1/graph/$2"; }
runlint(){ OUT="$(bash "$LINT" "$1" 2>&1)"; RC=$?; }
runexplain(){ OUT="$(bash "$LINT" --explain "$@" 2>&1)"; RC=$?; }

# 1. clean valid graph
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "q?"
---
Body.'
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: validated
edges:
  - {rel: validates, to: EXP-001}
---
Body.'
runlint "$d"
[ "$RC" -eq 0 ] && ok "clean graph exits 0" || no "clean graph exits 0" "rc=$RC out=$OUT"

# 2. dangling depends_on
d="$(newfix)"
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-999}
---
Body.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "dangling depends_on edge to missing node NODE-999"; } \
  && ok "dangling depends_on -> error, exit 1" || no "dangling depends_on" "rc=$RC out=$OUT"

# 3. dangling non-depends_on edge (proves all relations are checked)
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "q?"
edges:
  - {rel: validates, to: THEORY-999}
---
Body.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "dangling validates edge to missing node THEORY-999"; } \
  && ok "dangling validates -> error" || no "dangling validates" "rc=$RC out=$OUT"

# 4. dangling wiki edge: wiki/ is a repo-relative path like any other, so a missing page is the
#    generic missing-target error (not a git repo here, so plain existence decides)
d="$(newfix)"
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: validated
edges:
  - {rel: motivated_by, to: wiki/missing.md}
---
Body.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "NODE-001: motivated_by edge target wiki/missing.md: no node with this ID and no such file"; } \
  && ok "dangling wiki edge -> error" || no "dangling wiki edge" "rc=$RC out=$OUT"

# 5. invalid kind
d="$(newfix)"
node "$d" X-001.md '---
id: X-001
kind: banana
status: complete
---
Body.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "invalid kind"; } \
  && ok "invalid kind -> error" || no "invalid kind" "rc=$RC out=$OUT"

# 6. invalid status
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: banana
question: "q?"
---
Body.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "invalid status"; } \
  && ok "invalid status -> error" || no "invalid status" "rc=$RC out=$OUT"

# 7. duplicate id
d="$(newfix)"
node "$d" a.md '---
id: EXP-001
kind: experiment
status: complete
question: "q?"
---
A.'
node "$d" b.md '---
id: EXP-001
kind: experiment
status: running
question: "q?"
---
B.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "duplicate id"; } \
  && ok "duplicate id -> error" || no "duplicate id" "rc=$RC out=$OUT"

# 8. depends_on cycle
d="$(newfix)"
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-002}
---
A.'
node "$d" NODE-002.md '---
id: NODE-002
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-001}
---
B.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "cycle"; } \
  && ok "depends_on cycle -> error" || no "depends_on cycle" "rc=$RC out=$OUT"

# 9. invalidation inconsistency + positive control
d="$(newfix)"
node "$d" NODE-003.md '---
id: NODE-003
kind: pipeline_node
status: invalidated
---
Bad retriever.'
node "$d" NODE-004.md '---
id: NODE-004
kind: pipeline_node
status: assumed_working
edges:
  - {rel: depends_on, to: NODE-003}
---
Downstream not blocked.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "depends_on invalidated node NODE-003 but is not blocked"; } \
  && ok "invalidation inconsistency -> error" || no "invalidation inconsistency" "rc=$RC out=$OUT"
node "$d" NODE-004.md '---
id: NODE-004
kind: pipeline_node
status: blocked
edges:
  - {rel: depends_on, to: NODE-003}
---
Now blocked.'
runlint "$d"
[ "$RC" -eq 0 ] && ok "invalidation consistency (downstream blocked) -> exit 0" || no "invalidation positive control" "rc=$RC out=$OUT"

# 10. warnings only (empty body + experiment missing question) -> exit 0
d="$(newfix)"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
---
'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: running
---
Body but no question.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "WARNINGS"; } \
  && ok "warnings-only -> exit 0" || no "warnings-only exit 0" "rc=$RC out=$OUT"

# 11. no graph/ dir -> exit 0
d="$(mktemp -d)"
runlint "$d"
[ "$RC" -eq 0 ] && ok "no graph/ dir -> exit 0" || no "no graph dir" "rc=$RC out=$OUT"

# 12. transitive invalidation: C invalidated, B blocked, A depends_on B but NOT blocked -> error.
#     IDs keep the PREFIX-NNN shape (003 = C, 002 = B, 001 = A): a target outside that pattern reads
#     as a repo-relative path, and a lettered ID like NODE-001 would be a missing-path error (case 40).
d="$(newfix)"
node "$d" NODE-003.md '---
id: NODE-003
kind: pipeline_node
status: invalidated
---
Bad retriever.'
node "$d" NODE-002.md '---
id: NODE-002
kind: pipeline_node
status: blocked
edges:
  - {rel: depends_on, to: NODE-003}
---
Correctly blocked.'
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: assumed_working
edges:
  - {rel: depends_on, to: NODE-002}
---
Rests on a blocked node but not blocked itself.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "NODE-001: depends_on blocked node NODE-002 but is not blocked"; } \
  && ok "transitive invalidation (multi-hop) -> error" || no "transitive invalidation" "rc=$RC out=$OUT"
# positive control: block NODE-001 too -> whole chain consistent, exit 0
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: blocked
edges:
  - {rel: depends_on, to: NODE-002}
---
Now blocked, chain consistent.'
runlint "$d"
[ "$RC" -eq 0 ] && ok "transitive invalidation positive control (whole chain blocked) -> exit 0" \
  || no "transitive invalidation positive control" "rc=$RC out=$OUT"

# 13. block-style edge (split across lines) is unreadable -> plain error, exit 1 (fail closed)
d="$(newfix)"
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: untested
edges:
  - rel: depends_on
    to: NODE-999
---
Edge written block-style instead of flat.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "couldn't read an edge"; } \
  && ok "block-style edge -> error (not silently dropped)" || no "block-style edge error" "rc=$RC out=$OUT"

# 14. malformed frontmatter -> error, and a sibling valid node is still checked (non-fatal)
d="$(newfix)"
node "$d" BAD-001.md '---
id: BAD-001
kind: experiment
status: running
Body with no closing fence.'
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-999}
---
Valid node with a dangling edge.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "malformed frontmatter" \
  && echo "$OUT" | grep -q "dangling depends_on edge to missing node NODE-999"; } \
  && ok "malformed frontmatter -> error, run not aborted (sibling still checked)" \
  || no "malformed frontmatter non-fatal" "rc=$RC out=$OUT"

# 15. tolerant parse: a space in "rel :" still reads the edge, so a dangling ref is caught (was a false negative)
d="$(newfix)"
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: untested
edges:
  - {rel : depends_on, to: NODE-999}
---
Edge with a stray space before the colon.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "dangling depends_on edge to missing node NODE-999"; } \
  && ok "tolerant parse (rel : space) -> dangling caught, not silently dropped" \
  || no "tolerant parse rel-space" "rc=$RC out=$OUT"

# 16. tolerant parse: a trailing edge field still resolves the target, so a dangling ref is caught
d="$(newfix)"
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-999, weight: 1}
---
Edge with an extra key after to:.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "dangling depends_on edge to missing node NODE-999"; } \
  && ok "tolerant parse (trailing field) -> dangling caught, not silently dropped" \
  || no "tolerant parse trailing-field" "rc=$RC out=$OUT"

# 17. observation node with a status value -> invalid status error (observation has no status vocab)
d="$(newfix)"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
status: complete
---
Observations do not carry a status.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "invalid status"; } \
  && ok "observation with status -> error" || no "observation with status" "rc=$RC out=$OUT"

# 18. missing kind -> error
d="$(newfix)"
node "$d" X-001.md '---
id: X-001
status: complete
---
No kind field.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "missing kind"; } \
  && ok "missing kind -> error" || no "missing kind" "rc=$RC out=$OUT"

# 19. non-observation kind missing status -> warning only, exit 0
d="$(newfix)"
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
---
A pipeline node with no status.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "missing status"; } \
  && ok "missing status (non-observation) -> warning, exit 0" || no "missing status warning" "rc=$RC out=$OUT"

# 20. self-loop cycle (length-1) -> error, with the node named in the cycle path
d="$(newfix)"
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-001}
---
Depends on itself.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "depends_on cycle: NODE-001 -> NODE-001"; } \
  && ok "self-loop cycle -> error with path" || no "self-loop cycle" "rc=$RC out=$OUT"

# 21. cycle path is reported in order (stronger than just grep 'cycle')
d="$(newfix)"
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-002}
---
A.'
node "$d" NODE-002.md '---
id: NODE-002
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-001}
---
B.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -qE "depends_on cycle: NODE-00[12] -> NODE-00[12] -> NODE-00[12]"; } \
  && ok "cycle reported as ordered path" || no "cycle ordered path" "rc=$RC out=$OUT"

# 22. provenance (inline list form): every declared path resolves -> clean, exit 0
d="$(newfix)"; mkdir -p "$d/results"; : > "$d/results/a.md"; : > "$d/results/b.tsv"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "q?"
result: "F1 0.8731"
provenance: [results/a.md, results/b.tsv]
---
Body.'
runlint "$d"
{ [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "provenance"; } \
  && ok "provenance inline list, all resolve -> clean" || no "provenance inline resolves" "rc=$RC out=$OUT"

# 23. provenance (block form): one path missing -> error naming the path, exit 1.
#     The fixture is not a git repo, so this also proves the plain existence check decides when
#     `git check-ignore` cannot run (exit 128 is "not ignored", never "ignored").
d="$(newfix)"; mkdir -p "$d/results"; : > "$d/results/a.md"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "q?"
provenance:
  - results/a.md
  - results/missing.md
---
Body.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "EXP-001: provenance path results/missing.md does not exist" \
  && ! echo "$OUT" | grep -q "results/a.md"; } \
  && ok "provenance block list, missing path -> error, resolving sibling silent" || no "provenance missing path" "rc=$RC out=$OUT"

# 24. a git-ignored provenance path is a WARNING, not an error, whether or not it exists locally:
#     the check must read the same on the developer machine and in a clean CI checkout.
d="$(newfix)"; (cd "$d" && git init -q && printf 'raw/\n' > .gitignore); mkdir -p "$d/raw"; : > "$d/raw/present.csv"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
provenance: [raw/present.csv]
---
Body.'
node "$d" OBS-002.md '---
id: OBS-002
kind: observation
provenance: [raw/absent.csv]
---
Body.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "OBS-001: provenance path raw/present.csv is ignored by git" \
  && echo "$OUT" | grep -q "OBS-002: provenance path raw/absent.csv is ignored by git" \
  && ! echo "$OUT" | grep -q "does not exist"; } \
  && ok "git-ignored provenance path -> warning only, exit 0 (present and absent alike)" \
  || no "git-ignored provenance path" "rc=$RC out=$OUT"

# 24b. a present-but-untracked path is a WARNING (it will be missing in every clone); a committed
#      path is silent; a per-machine ignore rule (core.excludesFile) does NOT count as ignored, so
#      the same missing path is an ERROR here exactly as it would be in CI.
d="$(newfix)"; mkdir -p "$d/results"; : > "$d/results/tracked.md"; : > "$d/results/loose.md"
(cd "$d" && git init -q && git add results/tracked.md && git -c user.email=t@t -c user.name=t commit -qm init)
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
provenance: [results/tracked.md, results/loose.md]
---
Body.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "OBS-001: provenance path results/loose.md exists but is not tracked by git" \
  && ! echo "$OUT" | grep -q "results/tracked.md"; } \
  && ok "untracked present path -> warning, tracked path silent" || no "untracked present path" "rc=$RC out=$OUT"
excl="$(mktemp)"; printf 'gone/\n' > "$excl"
node "$d" OBS-002.md '---
id: OBS-002
kind: observation
provenance: [gone/absent.csv]
---
Body.'
OUT="$(cd "$d" && git config core.excludesFile "$excl" && bash "$LINT" "$d" 2>&1)"; RC=$?
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "OBS-002: provenance path gone/absent.csv does not exist"; } \
  && ok "per-machine excludesFile rule does not downgrade a missing path to a warning" \
  || no "per-machine excludesFile" "rc=$RC out=$OUT"

# 24c. tolerant key match and inline-form edge cases: `provenance :` still reads; a trailing YAML
#      comment is not part of the path; an unterminated list is a readable error, not a bogus path.
d="$(newfix)"; mkdir -p "$d/results"; : > "$d/results/a.md"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
provenance : [results/a.md]  # from run 3
---
Body.'
node "$d" OBS-002.md '---
id: OBS-002
kind: observation
provenance: [results/missing.md
---
Body.'
node "$d" OBS-003.md '---
id: OBS-003
kind: observation
provenance : [results/nope.md]
---
Body.'
runlint "$d"
{ [ "$RC" -eq 1 ] && ! echo "$OUT" | grep -q "OBS-001" \
  && echo "$OUT" | grep -q "OBS-002: couldn't read provenance" \
  && echo "$OUT" | grep -q "OBS-003: provenance path results/nope.md does not exist"; } \
  && ok "spaced colon reads, trailing comment dropped, unterminated list is a readable error" \
  || no "provenance parse edge cases" "rc=$RC out=$OUT"

# 25. no provenance key -> the check is silent (graphs that never declare provenance are untouched)
d="$(newfix)"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
---
Body.'
runlint "$d"
{ [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -qi "provenance"; } \
  && ok "absent provenance key -> silent" || no "absent provenance key" "rc=$RC out=$OUT"

# 26. bare scalar form reads as a single path
d="$(newfix)"; mkdir -p "$d/results"; : > "$d/results/one.md"
node "$d" DEC-001.md '---
id: DEC-001
kind: decision
status: active
provenance: results/one.md
---
Body.'
runlint "$d"
[ "$RC" -eq 0 ] && ok "provenance bare scalar resolves" || no "provenance bare scalar" "rc=$RC out=$OUT"

# 27. absolute or parent-escaping paths are rejected as not repo-relative
d="$(newfix)"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
provenance: [/etc/hostname, ../outside.md]
---
Body.'
runlint "$d"
{ [ "$RC" -eq 1 ] && [ "$(echo "$OUT" | grep -c "must be repo-relative")" -eq 2 ]; } \
  && ok "absolute and ../ provenance paths -> error" || no "non-relative provenance paths" "rc=$RC out=$OUT"

# 28. reversed invalidated_by pair: each node claims the other invalidated it. Direction carries
#     the meaning, so one edge is wrong -> exactly one error naming both nodes and the relation, exit 1
d="$(newfix)"
node "$d" DEC-010.md '---
id: DEC-010
kind: decision
status: active
edges:
  - {rel: invalidated_by, to: EXP-028}
---
Says the experiment invalidated it.'
node "$d" EXP-028.md '---
id: EXP-028
kind: experiment
status: complete
question: "q?"
edges:
  - {rel: invalidated_by, to: DEC-010}
---
Says the decision invalidated it, the other way round.'
runlint "$d"
{ [ "$RC" -eq 1 ] && [ "$(echo "$OUT" | grep -c "^  E ")" -eq 1 ] \
  && echo "$OUT" | grep "mutual invalidated_by" | grep -q "DEC-010" \
  && echo "$OUT" | grep "mutual invalidated_by" | grep -q "EXP-028"; } \
  && ok "reversed invalidated_by pair -> one error naming both nodes and the relation" \
  || no "reversed invalidated_by pair" "rc=$RC out=$OUT"

# 29. reversed supersedes AND reversed part_of between the same two nodes -> one error per relation
#     (the dedupe key includes the relation, so the second finding is not swallowed by the first)
d="$(newfix)"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
edges:
  - {rel: supersedes, to: OBS-002}
  - {rel: part_of, to: OBS-002}
---
A.'
node "$d" OBS-002.md '---
id: OBS-002
kind: observation
edges:
  - {rel: supersedes, to: OBS-001}
  - {rel: part_of, to: OBS-001}
---
B.'
runlint "$d"
{ [ "$RC" -eq 1 ] && [ "$(echo "$OUT" | grep -c "^  E ")" -eq 2 ] \
  && echo "$OUT" | grep -q "mutual supersedes" && echo "$OUT" | grep -q "mutual part_of"; } \
  && ok "reversed supersedes and part_of on the same pair -> two errors, one per relation" \
  || no "two relations reversed on one pair" "rc=$RC out=$OUT"

# 30. different relations in opposite directions: A supersedes B, B part_of A -> no pair error, exit 0
d="$(newfix)"
node "$d" OBS-018.md '---
id: OBS-018
kind: observation
edges:
  - {rel: supersedes, to: EXP-007}
---
Supersedes the experiment.'
node "$d" EXP-007.md '---
id: EXP-007
kind: experiment
status: complete
question: "q?"
edges:
  - {rel: part_of, to: OBS-018}
---
Part of the observation.'
runlint "$d"
{ [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "mutual"; } \
  && ok "different relations in opposite directions -> no pair error, exit 0" \
  || no "different relations opposite directions" "rc=$RC out=$OUT"

# 31. self-loop on part_of -> error naming the node
d="$(newfix)"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
edges:
  - {rel: part_of, to: OBS-001}
---
Part of itself.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "OBS-001: part_of edge to itself"; } \
  && ok "self-loop part_of -> error naming the node" || no "self-loop part_of" "rc=$RC out=$OUT"

# 32. reversed pair where one edge carries a trailing field -> still caught (the target capture stops at the comma)
d="$(newfix)"
node "$d" DEC-001.md '---
id: DEC-001
kind: decision
status: active
edges:
  - {rel: supersedes, to: DEC-002, note: x}
---
A.'
node "$d" DEC-002.md '---
id: DEC-002
kind: decision
status: active
edges:
  - {rel: supersedes, to: DEC-001}
---
B.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep "mutual supersedes" | grep -q "DEC-001" \
  && echo "$OUT" | grep "mutual supersedes" | grep -q "DEC-002"; } \
  && ok "reversed pair with a trailing edge field -> still caught" \
  || no "reversed pair trailing field" "rc=$RC out=$OUT"

# 33. mutual depends_on belongs to the cycle detector: reported once as a cycle, not again as a pair
d="$(newfix)"
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-002}
---
A.'
node "$d" NODE-002.md '---
id: NODE-002
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-001}
---
B.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "depends_on cycle" && ! echo "$OUT" | grep -q "mutual" \
  && [ "$(echo "$OUT" | grep -c "^  E ")" -eq 1 ]; } \
  && ok "mutual depends_on -> cycle error only, no pair error" || no "mutual depends_on not duplicated" "rc=$RC out=$OUT"

# 34. three-node part_of ring (A -> B -> C -> A) is not a reversed pair: the check is pairwise by design, exit 0
d="$(newfix)"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
edges:
  - {rel: part_of, to: OBS-002}
---
A.'
node "$d" OBS-002.md '---
id: OBS-002
kind: observation
edges:
  - {rel: part_of, to: OBS-003}
---
B.'
node "$d" OBS-003.md '---
id: OBS-003
kind: observation
edges:
  - {rel: part_of, to: OBS-001}
---
C.'
runlint "$d"
{ [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "mutual"; } \
  && ok "three-node part_of ring -> no pair error (pairwise only)" || no "part_of ring" "rc=$RC out=$OUT"

# 35. repo-relative edge target: a committed docs/plans/x.md is silent, exit 0, and
#     nothing in the output mentions the edge; the retired "unrecognized" warning never appears
d="$(newfix)"; mkdir -p "$d/docs/plans"; : > "$d/docs/plans/x.md"
(cd "$d" && git init -q && git add docs/plans/x.md && git -c user.email=t@t -c user.name=t commit -qm init)
node "$d" THEORY-001.md '---
id: THEORY-001
kind: theory
status: idea
edges:
  - {rel: motivated_by, to: docs/plans/x.md}
---
Body.'
runlint "$d"
{ [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "docs/plans/x.md" && ! echo "$OUT" | grep -q "motivated_by" \
  && ! echo "$OUT" | grep -q "unrecognized"; } \
  && ok "tracked repo-relative edge target -> silent, exit 0, no 'unrecognized'" \
  || no "tracked edge target" "rc=$RC out=$OUT"

# 36. repo-relative edge target: a path matched by the repo .gitignore is silent
#     whether or not it exists locally. A link to a private plan document is legitimate and permanent,
#     so unlike provenance there is no warning here: a nudge nobody can act on is the hygiene problem
#     this check replaces.
d="$(newfix)"; (cd "$d" && git init -q && printf 'docs/plans/\n' > .gitignore); mkdir -p "$d/docs/plans"; : > "$d/docs/plans/present.md"
node "$d" THEORY-001.md '---
id: THEORY-001
kind: theory
status: idea
edges:
  - {rel: motivated_by, to: docs/plans/present.md}
---
Body.'
node "$d" THEORY-002.md '---
id: THEORY-002
kind: theory
status: idea
edges:
  - {rel: motivated_by, to: docs/plans/absent.md}
---
Body.'
runlint "$d"
{ [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "docs/plans"; } \
  && ok "git-ignored edge target -> silent, present and absent alike" || no "git-ignored edge target" "rc=$RC out=$OUT"

# 37. repo-relative edge target: not ignored and not on disk -> error naming the
#     path and both readings of the target, exit 1
d="$(newfix)"; (cd "$d" && git init -q)
node "$d" THEORY-001.md '---
id: THEORY-001
kind: theory
status: idea
edges:
  - {rel: motivated_by, to: docs/plans/missing.md}
---
Body.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "THEORY-001: motivated_by edge target docs/plans/missing.md: no node with this ID and no such file"; } \
  && ok "missing repo-relative edge target -> error naming the path and both readings" \
  || no "missing edge target" "rc=$RC out=$OUT"

# 38. present-but-untracked edge target -> warning (it will be missing in every clone), exit 0
d="$(newfix)"; mkdir -p "$d/docs/plans"; : > "$d/docs/plans/loose.md"; (cd "$d" && git init -q)
node "$d" THEORY-001.md '---
id: THEORY-001
kind: theory
status: idea
edges:
  - {rel: motivated_by, to: docs/plans/loose.md}
---
Body.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "THEORY-001: motivated_by edge target docs/plans/loose.md exists but is not tracked by git" \
  && ! echo "$OUT" | grep -q "unrecognized"; } \
  && ok "untracked present edge target -> warning, exit 0" || no "untracked edge target" "rc=$RC out=$OUT"

# 39. wiki/ follows the same rule as any other path: a page matched by the repo .gitignore is silent
#     whether present or absent (case 4 covers the missing, not-ignored page)
d="$(newfix)"; (cd "$d" && git init -q && printf 'wiki/\n' > .gitignore); mkdir -p "$d/wiki"; : > "$d/wiki/present.md"
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: validated
edges:
  - {rel: motivated_by, to: wiki/present.md}
  - {rel: motivated_by, to: wiki/absent.md}
---
Body.'
runlint "$d"
{ [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "wiki/"; } \
  && ok "git-ignored wiki/ page -> silent, present and absent alike" || no "git-ignored wiki page" "rc=$RC out=$OUT"

# 40. lowercase node-ID typo: `node-004` does not match the ID pattern, so it is read as a path; it is
#     neither, and the error says so in both readings (fail closed, legible). Not a git repo.
d="$(newfix)"
node "$d" NODE-004.md '---
id: NODE-004
kind: pipeline_node
status: validated
---
The real node.'
node "$d" NODE-005.md '---
id: NODE-005
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: node-004}
---
Typo in the target case.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "NODE-005: depends_on edge target node-004: no node with this ID" \
  && ! echo "$OUT" | grep -q "unrecognized"; } \
  && ok "lowercase node-ID typo -> error naming both readings" || no "lowercase node-ID typo" "rc=$RC out=$OUT"

# 41. a per-machine core.excludesFile rule matching the missing target does NOT count as ignored (the
#     same rule as provenance, case 24b): the missing path is an error here exactly as it would be in CI
d="$(newfix)"; (cd "$d" && git init -q)
excl="$(mktemp)"; printf 'gone/\n' > "$excl"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
edges:
  - {rel: motivated_by, to: gone/plan.md}
---
Body.'
OUT="$(cd "$d" && git config core.excludesFile "$excl" && bash "$LINT" "$d" 2>&1)"; RC=$?
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "OBS-001: motivated_by edge target gone/plan.md: no node with this ID and no such file"; } \
  && ok "per-machine excludesFile rule does not silence a missing edge target" \
  || no "per-machine excludesFile edge target" "rc=$RC out=$OUT"

# 42. no git at all (plain directory): existence decides. A present file target is silent; a missing
#     one is an error, and the present sibling stays silent beside it.
d="$(newfix)"; mkdir -p "$d/docs"; : > "$d/docs/notes.md"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
edges:
  - {rel: motivated_by, to: docs/notes.md}
---
Body.'
runlint "$d"
{ [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "docs/notes.md" && ! echo "$OUT" | grep -q "unrecognized"; } \
  && ok "non-git fixture, present edge target -> silent" || no "non-git present edge target" "rc=$RC out=$OUT"
node "$d" OBS-002.md '---
id: OBS-002
kind: observation
edges:
  - {rel: motivated_by, to: docs/gone.md}
---
Body.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "OBS-002: motivated_by edge target docs/gone.md: no node with this ID and no such file" \
  && ! echo "$OUT" | grep -q "docs/notes.md"; } \
  && ok "non-git fixture, missing edge target -> error, present sibling silent" \
  || no "non-git missing edge target" "rc=$RC out=$OUT"

# 43. quoted targets: the edge capture keeps YAML quotes, so they are stripped before classifying.
#     A quoted tracked path and a quoted (double or single) existing node ID are all silent; a quoted
#     dangling node ID is still the dangling-node error, and the message names it without its quotes.
d="$(newfix)"; mkdir -p "$d/docs/plans"; : > "$d/docs/plans/x.md"
(cd "$d" && git init -q && git add docs/plans/x.md && git -c user.email=t@t -c user.name=t commit -qm init)
node "$d" NODE-004.md '---
id: NODE-004
kind: pipeline_node
status: validated
---
The real node.'
node "$d" THEORY-001.md "---
id: THEORY-001
kind: theory
status: idea
edges:
  - {rel: motivated_by, to: \"docs/plans/x.md\"}
  - {rel: depends_on, to: \"NODE-004\"}
  - {rel: validates, to: 'NODE-004'}
---
Body."
runlint "$d"
{ [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "docs/plans/x.md" && ! echo "$OUT" | grep -q "NODE-004" \
  && ! echo "$OUT" | grep -q "unrecognized"; } \
  && ok "quoted path and quoted node-ID targets -> silent, exit 0" || no "quoted targets silent" "rc=$RC out=$OUT"
node "$d" THEORY-002.md '---
id: THEORY-002
kind: theory
status: idea
edges:
  - {rel: depends_on, to: "NODE-999"}
---
Body.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "THEORY-002: dangling depends_on edge to missing node NODE-999"; } \
  && ok "quoted dangling node ID -> dangling-node error, quotes stripped" || no "quoted dangling node ID" "rc=$RC out=$OUT"

# 44. absolute or parent-escaping edge targets are rejected as not repo-relative (the same rule as
#     provenance, case 27)
d="$(newfix)"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
edges:
  - {rel: motivated_by, to: /etc/hostname}
  - {rel: motivated_by, to: ../outside.md}
---
Body.'
runlint "$d"
{ [ "$RC" -eq 1 ] && [ "$(echo "$OUT" | grep -c "edge target.*must be repo-relative")" -eq 2 ]; } \
  && ok "absolute and ../ edge targets -> error" || no "non-relative edge targets" "rc=$RC out=$OUT"

# 45. an edge to an EXISTING node whose ID does not match PREFIX-NNN is a node target, not a
#     missing path: the lint never validated IDs, so odd IDs must not start failing on upgrade.
d="$(newfix)"
node "$d" NODE-A.md '---
id: NODE-A
kind: pipeline_node
status: validated
---
Body.'
node "$d" NODE-B.md '---
id: NODE-B
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-A}
---
Body.'
runlint "$d"
{ [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "NODE-A"; } \
  && ok "edge to an existing off-pattern node ID is silent" || no "off-pattern existing node target" "rc=$RC out=$OUT"

# 46. --explain: NODE-008 validates DEC-002, whose first body line is a plain sentence -> one
#     line per edge of the named node in the form SRC rel TARGET "summary", then the normal report,
#     exit 0. DEC-002 carries an edge of its own so the scope is shown to exclude it. The fixture is
#     reused by cases 54 and 56.
ae4="$(newfix)"
node "$ae4" OBS-001.md '---
id: OBS-001
kind: observation
---
Reviewers asked for proceedings coverage.'
node "$ae4" DEC-002.md '---
id: DEC-002
kind: decision
status: active
edges:
  - {rel: motivated_by, to: OBS-001}
---
Conference proceedings first, behind a pluggable document adapter

Rationale follows.'
node "$ae4" NODE-008.md '---
id: NODE-008
kind: pipeline_node
status: validated
edges:
  - {rel: validates, to: DEC-002}
---
Proceedings adapter.'
runexplain "$ae4" NODE-008
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -qF 'NODE-008 validates DEC-002 "Conference proceedings first, behind a pluggable document adapter"' \
  && echo "$OUT" | grep -q '^EXPLAIN (1 edges):$' && ! echo "$OUT" | grep -q 'DEC-002 motivated_by'; } \
  && ok "--explain NODE-008 -> SRC rel TARGET \"first body line\", scoped to the named node" \
  || no "--explain scoped" "rc=$RC out=$OUT"

# 47. --explain: a first body line that is a markdown heading is rendered verbatim, no stripping
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "q?"
---
## Result

Hybrid wins.'
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: validated
edges:
  - {rel: validates, to: EXP-001}
---
Body.'
runexplain "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -qF 'NODE-001 validates EXP-001 "## Result"'; } \
  && ok "--explain: heading first line rendered verbatim" || no "--explain heading" "rc=$RC out=$OUT"

# 48. --explain: a first body line that is a table row is rendered verbatim
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "q?"
---
| a | b |
|---|---|
| 1 | 2 |'
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: validated
edges:
  - {rel: validates, to: EXP-001}
---
Body.'
runexplain "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -qF 'NODE-001 validates EXP-001 "| a | b |"'; } \
  && ok "--explain: table-row first line rendered verbatim" || no "--explain table row" "rc=$RC out=$OUT"

# 49. --explain: a 200-character first line is cut to exactly 80 characters plus `...` (the closing
#     quote in the expected string pins the length: an 81st character would break the match)
d="$(newfix)"
long="$(printf 'x%.0s' $(seq 1 200))"
node "$d" OBS-001.md "---
id: OBS-001
kind: observation
---
$long"
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: validated
edges:
  - {rel: motivated_by, to: OBS-001}
---
Body.'
want="$(printf 'x%.0s' $(seq 1 80))..."
runexplain "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -qF "NODE-001 motivated_by OBS-001 \"$want\""; } \
  && ok "--explain: 200-character first line -> 80 characters plus ..." || no "--explain truncation" "rc=$RC out=$OUT"

# 50. --explain: an empty body renders as (empty body); the existing empty-body warning is unchanged
d="$(newfix)"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
---'
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: validated
edges:
  - {rel: motivated_by, to: OBS-001}
---
Body.'
runexplain "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -qF 'NODE-001 motivated_by OBS-001 "(empty body)"' \
  && echo "$OUT" | grep -q "OBS-001: empty body (claimed but unlogged)"; } \
  && ok "--explain: empty body -> (empty body), warning unchanged" || no "--explain empty body" "rc=$RC out=$OUT"

# 51. --explain: a file target whose content opens with a frontmatter block renders the first
#     non-blank line after the closing fence, and the tracked path stays silent in the report
d="$(newfix)"; mkdir -p "$d/wiki"
printf -- '---\ntitle: Chunking\ntags: [notes]\n---\n\n# Chunking notes\n\nMore text.\n' > "$d/wiki/x.md"
(cd "$d" && git init -q && git add wiki/x.md && git -c user.email=t@t -c user.name=t commit -qm init)
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: validated
edges:
  - {rel: motivated_by, to: wiki/x.md}
---
Body.'
runexplain "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -qF 'NODE-001 motivated_by wiki/x.md "# Chunking notes"' \
  && [ "$(echo "$OUT" | grep -c 'wiki/x.md')" -eq 1 ]; } \
  && ok "--explain: file target with frontmatter -> first line after the fence" \
  || no "--explain file target frontmatter" "rc=$RC out=$OUT"

# 52. --explain: a missing target (path or node ID) renders as (missing) AND the missing-target
#     errors are still reported, exit 1: explain is rendering only, never a substitute for the check
d="$(newfix)"
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: untested
edges:
  - {rel: motivated_by, to: docs/gone.md}
  - {rel: depends_on, to: NODE-999}
---
Body.'
runexplain "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -qF 'NODE-001 motivated_by docs/gone.md "(missing)"' \
  && echo "$OUT" | grep -qF 'NODE-001 depends_on NODE-999 "(missing)"' \
  && echo "$OUT" | grep -q "NODE-001: motivated_by edge target docs/gone.md: no node with this ID and no such file" \
  && echo "$OUT" | grep -q "NODE-001: dangling depends_on edge to missing node NODE-999"; } \
  && ok "--explain: missing targets -> (missing), errors still reported, exit 1" \
  || no "--explain missing target" "rc=$RC out=$OUT"

# 53. --explain scope: two named IDs render only their edges; an ID that is not a node prints one
#     (no node ...) line and the other edges still render; the count in the header is of rendered edges
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "q?"
---
Result line.'
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: validated
edges:
  - {rel: validates, to: EXP-001}
---
First.'
node "$d" NODE-002.md '---
id: NODE-002
kind: pipeline_node
status: validated
edges:
  - {rel: depends_on, to: NODE-001}
---
Second.'
node "$d" NODE-003.md '---
id: NODE-003
kind: pipeline_node
status: validated
edges:
  - {rel: depends_on, to: NODE-002}
---
Third.'
runexplain "$d" NODE-001 NODE-003 NODE-999
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^EXPLAIN (2 edges):$' \
  && echo "$OUT" | grep -qF 'NODE-001 validates EXP-001 "Result line."' \
  && echo "$OUT" | grep -qF 'NODE-003 depends_on NODE-002 "Second."' \
  && ! echo "$OUT" | grep -q 'NODE-002 depends_on' \
  && echo "$OUT" | grep -qF '  (no node NODE-999)'; } \
  && ok "--explain scope: only the named nodes' edges; unknown ID -> (no node ...) line" \
  || no "--explain scope" "rc=$RC out=$OUT"

# 54. --explain changes nothing below the block: on a graph with errors the exit code is still 1, on
#     a clean graph still 0, and the report after the EXPLAIN block (everything past its blank line)
#     is byte-identical to the run without the flag
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
---
No question, no status: two warnings.'
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-999}
  - {rel: validates, to: EXP-001}
---
Body.'
plain="$(bash "$LINT" "$d" 2>&1)"; prc=$?
expl="$(bash "$LINT" --explain "$d" 2>&1)"; erc=$?
rest="$(printf '%s\n' "$expl" | sed '1,/^$/d')"
{ [ "$prc" -eq 1 ] && [ "$erc" -eq 1 ] && [ "$rest" = "$plain" ] && printf '%s\n' "$expl" | head -1 | grep -q '^EXPLAIN (2 edges):$'; } \
  && ok "--explain on an erroring graph: exit 1, report after the block identical" \
  || no "--explain erroring graph" "prc=$prc erc=$erc plain=$plain expl=$expl"
plain="$(bash "$LINT" "$ae4" 2>&1)"; prc=$?
expl="$(bash "$LINT" --explain "$ae4" 2>&1)"; erc=$?
rest="$(printf '%s\n' "$expl" | sed '1,/^$/d')"
{ [ "$prc" -eq 0 ] && [ "$erc" -eq 0 ] && [ "$rest" = "$plain" ] && printf '%s\n' "$expl" | head -1 | grep -q '^EXPLAIN (2 edges):$'; } \
  && ok "--explain on a clean graph: exit 0, report after the block identical" \
  || no "--explain clean graph" "prc=$prc erc=$erc plain=$plain expl=$expl"

# 55. legacy invocation, `bash graph-lint.sh <dir>` and `bash graph-lint.sh` from inside the repo,
#     is byte-identical to the committed script (HEAD) on the case-54 graph and on the example graph:
#     adding the flag changed nothing for callers that pass zero or one positional
old="$(mktemp)"
if git -C "$REPO" show HEAD:plugin/scripts/graph-lint.sh > "$old" 2>/dev/null; then
  same=1
  for dir in "$d" "$REPO/examples/doc-search"; do
    a="$(bash "$old" "$dir" 2>&1)"; arc=$?
    b="$(bash "$LINT" "$dir" 2>&1)"; brc=$?
    { [ "$arc" -eq "$brc" ] && [ "$a" = "$b" ]; } || { same=0; diffnote="dir=$dir arc=$arc brc=$brc old=$a new=$b"; }
  done
  a="$(cd "$d" && bash "$old" 2>&1)"; arc=$?
  b="$(cd "$d" && bash "$LINT" 2>&1)"; brc=$?
  { [ "$arc" -eq "$brc" ] && [ "$a" = "$b" ]; } || { same=0; diffnote="zero-positional arc=$arc brc=$brc old=$a new=$b"; }
  [ "$same" -eq 1 ] && ok "legacy invocation output byte-identical to HEAD" || no "legacy invocation drift" "$diffnote"
else
  ok "legacy invocation pinned against HEAD (skipped: no git history to compare against)"
fi
rm -f "$old"

# 56. --explain grammar, both forms: from inside the repo `--explain NODE-008` takes `.` as the root
#     and the argument as an ID; `--explain <dir> NODE-008` names the root; `--explain <dir>` and a
#     bare `--explain` from inside the repo render every edge
a="$(cd "$ae4" && bash "$LINT" --explain NODE-008 2>&1)"; arc=$?
b="$(bash "$LINT" --explain "$ae4" NODE-008 2>&1)"; brc=$?
line='NODE-008 validates DEC-002 "Conference proceedings first, behind a pluggable document adapter"'
{ [ "$arc" -eq 0 ] && [ "$brc" -eq 0 ] && echo "$a" | grep -qF "$line" && echo "$b" | grep -qF "$line" \
  && echo "$a" | grep -q '^EXPLAIN (1 edges):$' && echo "$b" | grep -q '^EXPLAIN (1 edges):$'; } \
  && ok "--explain grammar: ID with implicit root and with explicit root both render the same line" \
  || no "--explain grammar, ID forms" "arc=$arc a=$a brc=$brc b=$b"
c="$(bash "$LINT" --explain "$ae4" 2>&1)"; crc=$?
e="$(cd "$ae4" && bash "$LINT" --explain 2>&1)"; erc=$?
{ [ "$crc" -eq 0 ] && [ "$erc" -eq 0 ] && echo "$c" | grep -q '^EXPLAIN (2 edges):$' && echo "$e" | grep -q '^EXPLAIN (2 edges):$' \
  && echo "$c" | grep -qF "$line" && echo "$e" | grep -qF "$line" \
  && echo "$c" | grep -qF 'DEC-002 motivated_by OBS-001 "Reviewers asked for proceedings coverage."' \
  && echo "$e" | grep -qF 'DEC-002 motivated_by OBS-001 "Reviewers asked for proceedings coverage."'; } \
  && ok "--explain grammar: no IDs, with and without an explicit root, render every edge" \
  || no "--explain grammar, no-ID forms" "crc=$crc c=$c erc=$erc e=$e"

echo "---"; echo "graph-lint test: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
