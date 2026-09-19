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

# 43b. quote-stripping changes verdicts, not only silence: a quoted depends_on target `"NODE-003"`
#      reaches the invalidation rule as NODE-003, so an invalidated target with an unblocked source is
#      the normal propagation error, exit 1 (the quotes never make the edge invisible to that rule)
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
  - {rel: depends_on, to: "NODE-003"}
---
Quoted target, not blocked.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "NODE-004: depends_on invalidated node NODE-003 but is not blocked"; } \
  && ok "quoted depends_on target to an invalidated node -> propagation error, exit 1" \
  || no "quoted depends_on invalidated" "rc=$RC out=$OUT"

# 43c. a quoted path target is captured whole, so a tracked file whose name holds a space or a comma
#      resolves: `to: "docs/my plan.md"` and `to: 'docs/a,b.md'` are silent, exit 0. Unquoted, the
#      capture still ends at the first space (the known limit): `to: docs/my plan.md` reads as
#      `docs/my`, and the missing-target error names that truncated path so the cause is visible.
d="$(newfix)"; mkdir -p "$d/docs"; : > "$d/docs/my plan.md"; : > "$d/docs/a,b.md"
(cd "$d" && git init -q && git add docs && git -c user.email=t@t -c user.name=t commit -qm init)
node "$d" THEORY-001.md "---
id: THEORY-001
kind: theory
status: idea
edges:
  - {rel: motivated_by, to: \"docs/my plan.md\"}
  - {rel: motivated_by, to: 'docs/a,b.md'}
---
Body."
runlint "$d"
{ [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "docs/"; } \
  && ok "quoted targets holding a space and a comma -> captured whole, tracked, silent" \
  || no "quoted target with space or comma" "rc=$RC out=$OUT"
node "$d" THEORY-002.md '---
id: THEORY-002
kind: theory
status: idea
edges:
  - {rel: motivated_by, to: docs/my plan.md}
---
Unquoted, the space ends the target.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "THEORY-002: motivated_by edge target docs/my: no node with this ID and no such file"; } \
  && ok "unquoted target with a space -> cut at the space (known limit), error names docs/my" \
  || no "unquoted target with space" "rc=$RC out=$OUT"

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

# 45b. an edge target that names a node FILE (`graph/NODE-003.md`) is not a path. Read as one it
#      resolves as a present or tracked file and slips past the dangling, invalidation-propagation,
#      mutual-pair and self-loop rules. Fail closed: an error naming the ID to use instead, exit 1,
#      for a depends_on to an invalidated node's file and for a part_of to the node's own file.
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
  - {rel: depends_on, to: graph/NODE-003.md}
---
Points at the file, not the node, and is not blocked.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "NODE-004: depends_on edge target graph/NODE-003.md names a node file; use its ID NODE-003"; } \
  && ok "edge target naming a node file -> error naming the ID, exit 1 (not read as a path)" \
  || no "node-file edge target" "rc=$RC out=$OUT"
node "$d" OBS-001.md '---
id: OBS-001
kind: observation
edges:
  - {rel: part_of, to: graph/OBS-001.md}
---
Part of its own file.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "OBS-001: part_of edge target graph/OBS-001.md names a node file; use its ID OBS-001"; } \
  && ok "part_of to the node's own file -> same error (the self-loop rule is bypassed otherwise)" \
  || no "node-file self target" "rc=$RC out=$OUT"

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

# 55. legacy invocation, `bash graph-lint.sh` from inside the repo and `bash graph-lint.sh <dir>`, is
#     pinned to a golden output written here as a literal: the exact report, byte for byte, and the
#     exit code, for a case-54 style graph and for the example graph. Both forms run from inside the
#     graph's directory (the positional is `.`) so the report names `./graph` and the literal is
#     stable. A negative control perturbs one printed string in a copy of the script and runs the
#     same comparison, which must FAIL: a pin that cannot fail pins nothing (the earlier form compared
#     the working tree to HEAD, the same file once committed).
golden(){   # golden SCRIPT DIR EXPECTED_FILE EXPECTED_RC: 0 when both legacy forms match byte for byte
  local script="$1" dir="$2" want="$3" wrc="$4" got rc form
  got="$(mktemp)"; GOLD_NOTE=""
  for form in zero-positional one-positional; do
    if [ "$form" = zero-positional ]; then (cd "$dir" && bash "$script" > "$got" 2>&1); rc=$?
    else (cd "$dir" && bash "$script" . > "$got" 2>&1); rc=$?; fi
    if [ "$rc" -ne "$wrc" ] || ! cmp -s "$got" "$want"; then
      GOLD_NOTE="$form: rc=$rc want=$wrc; diff (want vs got): $(diff "$want" "$got" | head -4 | tr '\n' ' ')"
      rm -f "$got"; return 1
    fi
  done
  rm -f "$got"; return 0
}
base="$(mktemp -d)"; d="$base/repo"; mkdir -p "$d/graph"
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
want="$(mktemp)"
cat > "$want" <<'EOF'
graph-lint: 2 node(s) in ./graph

ERRORS (1):
  E NODE-001: dangling depends_on edge to missing node NODE-999

WARNINGS (2):
  W EXP-001: missing status
  W EXP-001: experiment missing 'question'

1 error(s), 2 warning(s).
EOF
golden "$LINT" "$d" "$want" 1 \
  && ok "legacy invocation (zero and one positional) matches the golden report and exit code" \
  || no "legacy invocation golden" "$GOLD_NOTE"
want2="$(mktemp)"
cat > "$want2" <<'EOF'
graph-lint: 12 node(s) in ./graph
clean: no integrity problems found.

0 error(s), 0 warning(s).
EOF
golden "$LINT" "$REPO/examples/doc-search" "$want2" 0 \
  && ok "legacy invocation on examples/doc-search matches the golden report and exit code" \
  || no "legacy invocation golden, doc-search" "$GOLD_NOTE"
bad="$(mktemp)"; sed 's/error(s), /errors, /' "$LINT" > "$bad"
if golden "$bad" "$d" "$want" 1; then
  no "negative control: a script with one perturbed string must NOT match the golden (pin is dead)"
else
  ok "negative control: a script with one perturbed string fails the golden comparison (pin is live)"
  echo "  $GOLD_NOTE"
fi
rm -f "$bad" "$want" "$want2"

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

# 57. --explain summaries for the shapes a path target can take: a directory renders (directory); a
#     file holding a NUL byte renders (binary file); a file that opens a frontmatter fence and never
#     closes it renders the first non-blank line after the opening `---` (a bare `---` is not a
#     summary); an absolute or parent-escaping target renders (missing) and is never opened, so the
#     sentinel line inside those files appears nowhere in the output. Non-git, so the present targets
#     are silent in the report; the two escaping targets keep their repo-relative errors, exit 1.
base="$(mktemp -d)"; d="$base/repo"; mkdir -p "$d/graph" "$d/docs/sub"
printf 'abc\0def\n' > "$d/docs/bin.dat"
printf -- '---\ntitle: Open fence\nnever: closed\n' > "$d/docs/open.md"
printf 'OUTSIDE-SENTINEL-LINE\n' > "$base/outside.md"
node "$d" NODE-001.md "---
id: NODE-001
kind: pipeline_node
status: validated
edges:
  - {rel: motivated_by, to: docs/sub}
  - {rel: motivated_by, to: docs/bin.dat}
  - {rel: motivated_by, to: docs/open.md}
  - {rel: motivated_by, to: $base/outside.md}
  - {rel: motivated_by, to: ../outside.md}
---
Body."
runexplain "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -qF 'NODE-001 motivated_by docs/sub "(directory)"' \
  && [ "$(echo "$OUT" | grep -c 'docs/sub')" -eq 1 ]; } \
  && ok "--explain: directory target -> (directory), silent in the report" || no "--explain directory target" "rc=$RC out=$OUT"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -qF 'NODE-001 motivated_by docs/bin.dat "(binary file)"' \
  && [ "$(echo "$OUT" | grep -c 'docs/bin.dat')" -eq 1 ]; } \
  && ok "--explain: file with a NUL byte -> (binary file)" || no "--explain binary target" "rc=$RC out=$OUT"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -qF 'NODE-001 motivated_by docs/open.md "title: Open fence"' \
  && ! echo "$OUT" | grep -qF 'docs/open.md "---"'; } \
  && ok "--explain: unclosed frontmatter fence -> first line after the opening ---, not the bare fence" \
  || no "--explain unclosed fence" "rc=$RC out=$OUT"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -qF "NODE-001 motivated_by $base/outside.md \"(missing)\"" \
  && echo "$OUT" | grep -qF 'NODE-001 motivated_by ../outside.md "(missing)"' \
  && ! echo "$OUT" | grep -q 'OUTSIDE-SENTINEL-LINE' \
  && [ "$(echo "$OUT" | grep -c "edge target.*must be repo-relative")" -eq 2 ]; } \
  && ok "--explain: absolute and ../ targets -> (missing), never opened, errors still reported" \
  || no "--explain escaping target" "rc=$RC out=$OUT"

# 58. --explain root detection: a directory literally named NODE-008 beside graph/ must not be taken
#     as the root. From inside the repo `--explain NODE-008` is the node ID (a bare name with no
#     slash and no graph/ inside it is never a root); from the parent, the bare directory name IS the
#     root because it has a graph/ inside. The explicit-root forms in case 56 keep working.
d="$(newfix)"; mkdir -p "$d/NODE-008"
node "$d" DEC-002.md '---
id: DEC-002
kind: decision
status: active
---
Conference proceedings first.'
node "$d" NODE-008.md '---
id: NODE-008
kind: pipeline_node
status: validated
edges:
  - {rel: validates, to: DEC-002}
---
Proceedings adapter.'
line='NODE-008 validates DEC-002 "Conference proceedings first."'
a="$(cd "$d" && bash "$LINT" --explain NODE-008 2>&1)"; arc=$?
{ [ "$arc" -eq 0 ] && echo "$a" | grep -q '^EXPLAIN (1 edges):$' && echo "$a" | grep -qF "$line" \
  && ! echo "$a" | grep -q 'no graph/ directory'; } \
  && ok "--explain NODE-008 beside a directory named NODE-008 -> the ID, not the root" \
  || no "--explain ID shadowed by a directory" "arc=$arc a=$a"
b="$(cd "$(dirname "$d")" && bash "$LINT" --explain "$(basename "$d")" NODE-008 2>&1)"; brc=$?
{ [ "$brc" -eq 0 ] && echo "$b" | grep -q '^EXPLAIN (1 edges):$' && echo "$b" | grep -qF "$line"; } \
  && ok "--explain <bare dir name with graph/ inside> NODE-008 -> the root, then the ID" \
  || no "--explain bare root name" "brc=$brc b=$b"

# 59. `--explain` is accepted only as the first argument: anywhere else it is a usage error, exit 2,
#     with no report (legacy callers never pass the flag, so nothing that worked before changes)
OUT="$(bash "$LINT" "$d" --explain 2>&1)"; RC=$?
{ [ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "usage" && ! echo "$OUT" | grep -q "node(s) in" \
  && ! echo "$OUT" | grep -q "error(s)"; } \
  && ok "--explain after the root -> usage error, exit 2, no report" || no "--explain not first" "rc=$RC out=$OUT"

# 60. R8, first half: a planned experiment that carries a `config` and no `abandon_if` warns (the run
#     is specified well enough to pre-register its exit, so the nag lands where the habit matters);
#     the same experiment without a `config` is silent. Warn only: exit 0 both ways.
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: planned
question: "Does k=20 beat k=10?"
config: {retriever: hybrid, k: 20}
---
Planned with a config and no exit.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "W EXP-001: .*abandon_if"; } \
  && ok "planned experiment with a config and no abandon_if -> warning, exit 0" \
  || no "planned + config + no abandon_if warns" "rc=$RC out=$OUT"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: planned
question: "Does k=20 beat k=10?"
---
Planned, no config: nothing to pre-register yet.'
runlint "$d"
{ [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "abandon_if" && echo "$OUT" | grep -q "0 warning(s)"; } \
  && ok "planned experiment with no config -> silent about abandon_if" \
  || no "planned + no config silent" "rc=$RC out=$OUT"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: planned
question: "Does k=20 beat k=10?"
config: {retriever: hybrid, k: 20}
abandon_if: "nDCG@10 gain under 2 pts at n=200"
---
Planned with a config and a pre-registered exit.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "0 warning(s)"; } \
  && ok "planned experiment with a config and an abandon_if -> silent" \
  || no "planned + config + abandon_if silent" "rc=$RC out=$OUT"

# 61. R8, second half: a complete experiment that carries a `validates` edge and no `compared_to`
#     warns and still exits 0 when nothing else is wrong; with a `compared_to` it is silent.
d="$(newfix)"
node "$d" THEORY-001.md '---
id: THEORY-001
kind: theory
status: backtest
---
Hybrid beats vector-only.'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "Does hybrid beat vector-only?"
result: "+10 pts"
edges:
  - {rel: validates, to: THEORY-001}
---
Validates the theory but names no null.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "W EXP-001: .*compared_to" && echo "$OUT" | grep -q "1 warning(s)"; } \
  && ok "complete experiment with validates and no compared_to -> warning, exit 0" \
  || no "complete + validates + no compared_to warns" "rc=$RC out=$OUT"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "Does hybrid beat vector-only?"
result: "+10 pts"
compared_to: "vector-only retriever, same k and n"
edges:
  - {rel: validates, to: THEORY-001}
---
Validates the theory and names the comparison.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "0 warning(s)"; } \
  && ok "complete experiment with validates and a compared_to -> silent" \
  || no "complete + validates + compared_to silent" "rc=$RC out=$OUT"

# 62. `deferred` is an additive status for ideas and experiments only: both lint clean; on a theory
#     it is still an invalid status (deferred is a choice, blocked is a consequence, and a theory is
#     neither: it is shelved).
d="$(newfix)"
node "$d" IDEA-001.md '---
id: IDEA-001
kind: idea
status: deferred
---
Parked until the case count moves.'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: deferred
question: "Does the bound tighten with more cases?"
---
Parked behind the same event.'
runlint "$d"
{ [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q "invalid status"; } \
  && ok "status: deferred on an idea and an experiment -> lints clean" \
  || no "deferred idea and experiment clean" "rc=$RC out=$OUT"
node "$d" THEORY-001.md '---
id: THEORY-001
kind: theory
status: deferred
---
A theory cannot be deferred.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "E THEORY-001: invalid status 'deferred' for kind theory"; } \
  && ok "status: deferred on a theory -> invalid status error, exit 1" \
  || no "deferred theory errors" "rc=$RC out=$OUT"

# 63. R20: a node-form `reopen_when` (exactly `<NODE-ID> <status>`) whose node does not exist warns;
#     the same form naming an existing node is silent; a text trigger is never checked, even when it
#     happens to mention an ID that does not exist. A bare ID with no status is not the node form
#     either, so it reads as text and is silent. Warn only: exit 0 throughout.
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: running
question: "Does the reranker help?"
---
Running.'
node "$d" IDEA-001.md '---
id: IDEA-001
kind: idea
status: deferred
reopen_when: EXP-999 complete
---
Waiting on a run that is not in the graph.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "W IDEA-001: reopen_when .*EXP-999"; } \
  && ok "node-form reopen_when naming a missing node -> warning, exit 0" \
  || no "reopen_when missing node warns" "rc=$RC out=$OUT"
node "$d" IDEA-001.md '---
id: IDEA-001
kind: idea
status: deferred
reopen_when: "EXP-001 complete"
---
Waiting on the reranker run.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "0 warning(s)"; } \
  && ok "node-form reopen_when naming an existing node -> silent" \
  || no "reopen_when existing node silent" "rc=$RC out=$OUT"
node "$d" IDEA-001.md '---
id: IDEA-001
kind: idea
status: deferred
reopen_when: "when the case count passes 500 or EXP-999 lands"
---
A text trigger: listed, never evaluated.'
node "$d" IDEA-002.md '---
id: IDEA-002
kind: idea
status: deferred
reopen_when: EXP-999
---
A bare ID with no status is not the node form.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "0 warning(s)"; } \
  && ok "text reopen_when triggers (prose, bare ID) -> never checked, silent" \
  || no "text reopen_when silent" "rc=$RC out=$OUT"

# 64. The four exit-side fields and `reopen_when` are flat optional keys the lint reads and never
#     rejects: a complete experiment carrying all four lints clean, and an `exit_outcome` outside
#     crossed or overridden (`maybe`) lints clean too (it is read as absent, fail-closed to inert).
d="$(newfix)"
node "$d" THEORY-001.md '---
id: THEORY-001
kind: theory
status: backtest
---
Hybrid beats vector-only.'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "Does hybrid beat vector-only?"
config: {retriever: hybrid, k: 10}
result: "+1 pt, inside the bound"
abandon_if: "gain under 2 pts at n=200"
compared_to: "vector-only retriever"
bound: "2 pts nDCG@10"
exit_outcome: crossed
edges:
  - {rel: validates, to: THEORY-001}
---
Crossed its own exit; recorded on the marker, the run stays complete.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "clean: no integrity problems found"; } \
  && ok "complete experiment with all four exit-side fields -> clean" \
  || no "all four exit fields clean" "rc=$RC out=$OUT"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "Does hybrid beat vector-only?"
compared_to: "vector-only retriever"
exit_outcome: maybe
edges:
  - {rel: validates, to: THEORY-001}
---
An unrecognized exit_outcome is read as absent, never as an error.'
runlint "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "clean: no integrity problems found"; } \
  && ok "exit_outcome: maybe -> lints clean (read as absent)" \
  || no "exit_outcome maybe clean" "rc=$RC out=$OUT"

# --precheck (U2). The block prints before the report, `PRECHECK:` first, one finding per line with
# a stable first token, a blank line, then the untouched report. `pre` isolates the block so the
# assertions below read only it and never match a report line by accident.
runpre(){ OUT="$(bash "$LINT" --precheck "$@" 2>&1)"; RC=$?; PRE="$(printf '%s\n' "$OUT" | sed -n '/^PRECHECK:$/,/^$/p')"; }
has(){ printf '%s\n' "$PRE" | grep -qxF "$1"; }        # exact line present in the block
lacks(){ ! printf '%s\n' "$PRE" | grep -q "$1"; }       # pattern absent from the block

# 65. AE1: a theory whose next_gate names a complete node prints STALE_GATE with both IDs and the
#     node's status; a gate naming a planned node prints nothing. GATE_CONTEXT counts the complete
#     experiments carrying part_of or motivated_by edges to each non-shelved theory, context only.
d="$(newfix)"
node "$d" THEORY-001.md '---
id: THEORY-001
kind: theory
status: backtest
next_gate: "EXP-001 beats vector-only by 5 pts nDCG -> paper_trade"
---
Hybrid beats vector-only.'
node "$d" THEORY-002.md '---
id: THEORY-002
kind: theory
status: idea
next_gate: "EXP-002 recovers 80% of the precision lost to chunking"
---
Reranking recovers chunking loss.'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "Does hybrid beat vector-only?"
result: "+6 pts nDCG@10"
compared_to: "vector-only"
edges:
  - {rel: part_of, to: THEORY-001}
---
Done. The gate it was run for still names it.'
node "$d" EXP-002.md '---
id: EXP-002
kind: experiment
status: planned
question: "Does the reranker recover chunking loss?"
edges:
  - {rel: motivated_by, to: THEORY-002}
---
Not run yet.'
runpre "$d"
{ [ "$RC" -eq 0 ] && has "STALE_GATE THEORY-001 EXP-001 complete" \
  && has "GATE_CONTEXT THEORY-001 1 completed experiments" && has "GATE_CONTEXT THEORY-002 0 completed experiments" \
  && lacks "STALE_GATE THEORY-002" && lacks "precheck: silent"; } \
  && ok "precheck: gate naming a complete node -> STALE_GATE with theory, node, status; planned node -> nothing" \
  || no "precheck STALE_GATE" "rc=$RC out=$OUT"
[ "$(printf '%s\n' "$PRE" | grep -c '^FUTILITY\|^JUDGMENT')" -eq 0 ] \
  && ok "precheck: no deferred items -> no FUTILITY and no JUDGMENT" \
  || no "precheck no deferred items" "pre=$PRE"

# 66. R16, the known false-positive shape: a gate that cites a completed node only as a BASELINE to
#     beat still prints STALE_GATE, because the rule is a substring match of node IDs against
#     terminal statuses (KTD3) and reads no meaning. Recorded here and in the changelog, not hidden:
#     the brief is expected to read the gate text and say so, and the rule never judges.
d="$(newfix)"
node "$d" THEORY-001.md '---
id: THEORY-001
kind: theory
status: backtest
next_gate: "beat EXP-001 (the baseline) by 2 pts nDCG on the same 200 queries"
---
The baseline is complete; the gate is not.'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "What does vector-only score?"
result: "0.41 nDCG@10"
---
The baseline run.'
runpre "$d"
{ [ "$RC" -eq 0 ] && has "STALE_GATE THEORY-001 EXP-001 complete"; } \
  && ok "precheck: gate citing a completed node as a baseline -> STALE_GATE (known false positive, R16)" \
  || no "precheck baseline false positive" "rc=$RC out=$OUT"

# 67. A shelved theory's gate is never checked and gets no context line; an abandoned experiment
#     attached to a theory does not make the gate stale unless the gate names it (R16); a gate that
#     does name an abandoned node, or a validated pipeline node, prints STALE_GATE with that status.
d="$(newfix)"
node "$d" THEORY-001.md '---
id: THEORY-001
kind: theory
status: shelved
next_gate: "EXP-001 beats vector-only"
---
Shelved: its gate is nobody'"'"'s next step.'
node "$d" THEORY-002.md '---
id: THEORY-002
kind: theory
status: backtest
next_gate: "EXP-002 lands a bounded null"
---
Live theory; EXP-003 was abandoned under it.'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "q?"
edges:
  - {rel: part_of, to: THEORY-001}
---
Complete, named only by the shelved gate.'
node "$d" EXP-002.md '---
id: EXP-002
kind: experiment
status: planned
question: "q?"
edges:
  - {rel: part_of, to: THEORY-002}
---
Planned.'
node "$d" EXP-003.md '---
id: EXP-003
kind: experiment
status: abandoned
question: "q?"
edges:
  - {rel: part_of, to: THEORY-002}
---
Abandoned, attached to THEORY-002, not named by its gate.'
runpre "$d"
{ [ "$RC" -eq 0 ] && lacks "STALE_GATE" && lacks "GATE_CONTEXT THEORY-001" \
  && has "GATE_CONTEXT THEORY-002 0 completed experiments" && has "precheck: silent"; } \
  && ok "precheck: shelved theory's gate never checked; attached abandoned node does not stale a gate that does not name it" \
  || no "precheck shelved and abandoned-attached" "rc=$RC out=$OUT"
node "$d" THEORY-002.md '---
id: THEORY-002
kind: theory
status: backtest
next_gate: "rerun EXP-003 once NODE-001 is validated"
---
Now the gate names the abandoned run and a validated node.'
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: validated
---
Validated.'
runpre "$d"
{ [ "$RC" -eq 0 ] && has "STALE_GATE THEORY-002 EXP-003 abandoned" && has "STALE_GATE THEORY-002 NODE-001 validated" \
  && lacks "STALE_GATE THEORY-001"; } \
  && ok "precheck: gate naming an abandoned node and a validated node -> STALE_GATE for each, with its status" \
  || no "precheck abandoned and validated named" "rc=$RC out=$OUT"

# 68. Exits. A complete experiment with abandon_if and no exit_outcome prints EXIT_PENDING with the
#     exit and the result side by side, `(no result)` when there is none; exit_outcome: crossed
#     prints EXIT_CROSSED and no EXIT_PENDING; overridden prints neither (AE7a). The pre-check
#     enumerates and never judges whether the result crossed the exit (KD10).
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "q?"
abandon_if: "gain under 2 pts at n=200"
result: "+1 pt, inside the bound"
---
Ran to completion; nobody has read the result against the exit yet.'
node "$d" EXP-002.md '---
id: EXP-002
kind: experiment
status: complete
question: "q?"
abandon_if: "no signal by epoch 10"
---
Complete with an exit and no recorded result.'
runpre "$d"
{ [ "$RC" -eq 0 ] && has 'EXIT_PENDING EXP-001 abandon_if="gain under 2 pts at n=200" result="+1 pt, inside the bound"' \
  && has 'EXIT_PENDING EXP-002 abandon_if="no signal by epoch 10" result=(no result)' && lacks "EXIT_CROSSED"; } \
  && ok "precheck: complete + abandon_if + no exit_outcome -> EXIT_PENDING with exit and result side by side" \
  || no "precheck EXIT_PENDING" "rc=$RC out=$OUT"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "q?"
abandon_if: "gain under 2 pts at n=200"
result: "+1 pt, inside the bound"
exit_outcome: crossed
---
The user recorded the crossing.'
node "$d" EXP-002.md '---
id: EXP-002
kind: experiment
status: complete
question: "q?"
abandon_if: "no signal by epoch 10"
result: "signal at epoch 12"
exit_outcome: overridden
---
The user declined the exit; it is never re-raised.'
runpre "$d"
{ [ "$RC" -eq 0 ] && has "EXIT_CROSSED EXP-001" && lacks "EXIT_PENDING" && lacks "EXP-002"; } \
  && ok "precheck: crossed -> EXIT_CROSSED only; overridden -> neither line (AE7a)" \
  || no "precheck EXIT_CROSSED / overridden" "rc=$RC out=$OUT"
node "$d" EXP-003.md '---
id: EXP-003
kind: experiment
status: running
question: "q?"
abandon_if: "no signal by epoch 10"
---
Still running: an exit on a run that has not finished is not pending.'
runpre "$d"
{ [ "$RC" -eq 0 ] && lacks "EXP-003"; } \
  && ok "precheck: a running experiment with an abandon_if prints no exit line" \
  || no "precheck running exit silent" "rc=$RC out=$OUT"

# 69. AE2: every deferred item carries a node-form trigger that has not fired and nothing blocking is
#     open, so FUTILITY prints with the count. A theory at backtest is present and neither blocks nor
#     enables it: theories never enter the futility rule.
d="$(newfix)"
node "$d" THEORY-001.md '---
id: THEORY-001
kind: theory
status: backtest
next_gate: "a bounded null on the reranker line"
---
Live theory.'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: running
question: "q?"
---
The run everything waits on.'
node "$d" IDEA-001.md '---
id: IDEA-001
kind: idea
status: deferred
reopen_when: "EXP-001 complete"
---
Parked behind the run.'
node "$d" EXP-002.md '---
id: EXP-002
kind: experiment
status: deferred
question: "q?"
reopen_when: "EXP-001 abandoned"
---
Parked behind the same run, the other way.'
runpre "$d"
{ [ "$RC" -eq 0 ] && lacks "FUTILITY" && lacks "JUDGMENT" && has "DEFERRED IDEA-001 EXP-001 complete"; } \
  && ok "precheck: a running experiment blocks FUTILITY (and JUDGMENT), deferred lines still print" \
  || no "precheck running blocks futility" "rc=$RC out=$OUT"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: planned
question: "q?"
---
Planned, not yet run.'
runpre "$d"
{ [ "$RC" -eq 0 ] && lacks "FUTILITY" && lacks "JUDGMENT"; } \
  && ok "precheck: a planned experiment blocks FUTILITY" || no "precheck planned blocks futility" "rc=$RC out=$OUT"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: abandoned
question: "q?"
---
Stopped early; the deferred items now wait on statuses it will never reach again or already has.'
node "$d" EXP-002.md '---
id: EXP-002
kind: experiment
status: deferred
question: "q?"
reopen_when: "EXP-001 running"
---
Parked behind a status the run does not hold.'
runpre "$d"
{ [ "$RC" -eq 0 ] && has "DEFERRED IDEA-001 EXP-001 complete" && has "DEFERRED EXP-002 EXP-001 running" \
  && has "FUTILITY 2 deferred, all node-form, none fired" && lacks "JUDGMENT" && lacks "FIRED" && lacks "precheck: silent"; } \
  && ok "precheck: all deferred items node-form and unfired, nothing blocking open -> FUTILITY (AE2)" \
  || no "precheck FUTILITY" "rc=$RC out=$OUT"
node "$d" IDEA-002.md '---
id: IDEA-002
kind: idea
status: open
---
One open idea: the honest answer is still "keep going".'
runpre "$d"
{ [ "$RC" -eq 0 ] && lacks "FUTILITY" && lacks "JUDGMENT"; } \
  && ok "precheck: one open idea blocks FUTILITY" || no "precheck open idea blocks futility" "rc=$RC out=$OUT"
node "$d" IDEA-002.md '---
id: IDEA-002
kind: idea
status: promoted
---
Promoted ideas are already experiments elsewhere; they block nothing.'
runpre "$d"
{ [ "$RC" -eq 0 ] && has "FUTILITY 2 deferred, all node-form, none fired"; } \
  && ok "precheck: a promoted idea does not block FUTILITY" || no "precheck promoted idea" "rc=$RC out=$OUT"

# 70. AE2a and decision (b): one text-form trigger, or one deferred item with no trigger at all,
#     turns FUTILITY into JUDGMENT with the count of triggers needing judgment; the missing trigger
#     prints as `(no trigger)`.
node "$d" IDEA-002.md '---
id: IDEA-002
kind: idea
status: deferred
reopen_when: "when the case count passes 500"
---
A sentence for a person to judge.'
runpre "$d"
{ [ "$RC" -eq 0 ] && has "DEFERRED IDEA-002 when the case count passes 500" \
  && has "JUDGMENT 1 triggers need judgment" && lacks "FUTILITY"; } \
  && ok "precheck: one text trigger -> JUDGMENT count, no FUTILITY (AE2a)" || no "precheck JUDGMENT text" "rc=$RC out=$OUT"
node "$d" IDEA-003.md '---
id: IDEA-003
kind: idea
status: deferred
---
Deferred with nothing that would reopen it.'
runpre "$d"
{ [ "$RC" -eq 0 ] && has "DEFERRED IDEA-003 (no trigger)" && has "JUDGMENT 2 triggers need judgment" && lacks "FUTILITY"; } \
  && ok "precheck: a deferred item with no reopen_when -> (no trigger), counted as judgment, never FUTILITY" \
  || no "precheck no trigger" "rc=$RC out=$OUT"
rm -f "$d/graph/IDEA-002.md"
runpre "$d"
{ [ "$RC" -eq 0 ] && has "JUDGMENT 1 triggers need judgment" && lacks "FUTILITY"; } \
  && ok "precheck: the missing trigger alone still prints JUDGMENT and no FUTILITY" \
  || no "precheck no trigger alone" "rc=$RC out=$OUT"

# 71. FIRED: a node-form trigger whose node has reached the named status prints FIRED beside its
#     DEFERRED line, and neither FUTILITY nor JUDGMENT (one fired, so not futile; all node-form, so
#     nothing to judge). The wrong status prints DEFERRED only. A missing node prints DEFERRED and
#     the U1 warning in the report; it is node-form and unfired, so the literal rule still says
#     FUTILITY, with the warning beside it naming the typo.
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "q?"
---
Done.'
node "$d" IDEA-001.md '---
id: IDEA-001
kind: idea
status: deferred
reopen_when: "EXP-001 complete"
---
Waiting on the run, which has finished.'
runpre "$d"
{ [ "$RC" -eq 0 ] && has "DEFERRED IDEA-001 EXP-001 complete" && has "FIRED IDEA-001 EXP-001 complete" \
  && lacks "FUTILITY" && lacks "JUDGMENT"; } \
  && ok "precheck: node-form trigger whose node reached the status -> FIRED, no FUTILITY, no JUDGMENT" \
  || no "precheck FIRED" "rc=$RC out=$OUT"
node "$d" IDEA-001.md '---
id: IDEA-001
kind: idea
status: deferred
reopen_when: "EXP-001 abandoned"
---
Waiting on a status the run does not hold.'
runpre "$d"
{ [ "$RC" -eq 0 ] && has "DEFERRED IDEA-001 EXP-001 abandoned" && lacks "FIRED" \
  && has "FUTILITY 1 deferred, all node-form, none fired"; } \
  && ok "precheck: trigger with the wrong status -> DEFERRED only, never FIRED" || no "precheck wrong status" "rc=$RC out=$OUT"
node "$d" IDEA-001.md '---
id: IDEA-001
kind: idea
status: deferred
reopen_when: "EXP-999 complete"
---
Waiting on a run that is not in the graph.'
runpre "$d"
{ [ "$RC" -eq 0 ] && has "DEFERRED IDEA-001 EXP-999 complete" && lacks "FIRED" \
  && has "JUDGMENT 1 triggers need judgment" && lacks "FUTILITY" \
  && echo "$OUT" | grep -q "W IDEA-001: reopen_when names missing node EXP-999"; } \
  && ok "precheck: trigger naming a missing node -> DEFERRED plus the U1 warning, JUDGMENT not FUTILITY, never FIRED" \
  || no "precheck missing node" "rc=$RC out=$OUT"

# 72. Clean graph: `PRECHECK:`, `precheck: silent`, a blank line, then the report byte-identical to
#     the run without the flag, exit code unchanged (0 clean, 1 erroring). A graph whose only lines
#     would be GATE_CONTEXT is still silent: context is not a finding.
plain="$(bash "$LINT" "$ae4" 2>&1)"; prc=$?
runpre "$ae4"
rest="$(printf '%s\n' "$OUT" | sed '1,/^$/d')"
{ [ "$prc" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$rest" = "$plain" ] \
  && [ "$(printf '%s\n' "$OUT" | sed -n '1p')" = "PRECHECK:" ] && [ "$(printf '%s\n' "$OUT" | sed -n '2p')" = "precheck: silent" ] \
  && [ -z "$(printf '%s\n' "$OUT" | sed -n '3p')" ]; } \
  && ok "precheck: clean graph -> PRECHECK:, precheck: silent, blank line, report unchanged, exit 0" \
  || no "precheck clean graph" "prc=$prc rc=$RC plain=$plain out=$OUT"
d="$(newfix)"
node "$d" THEORY-001.md '---
id: THEORY-001
kind: theory
status: backtest
next_gate: "a bounded null on the reranker line"
---
Live theory, nothing stale.'
node "$d" NODE-001.md '---
id: NODE-001
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-999}
---
Dangling on purpose.'
plain="$(bash "$LINT" "$d" 2>&1)"; prc=$?
runpre "$d"
rest="$(printf '%s\n' "$OUT" | sed '1,/^$/d')"
{ [ "$prc" -eq 1 ] && [ "$RC" -eq 1 ] && [ "$rest" = "$plain" ] \
  && has "GATE_CONTEXT THEORY-001 0 completed experiments" && has "precheck: silent"; } \
  && ok "precheck: erroring graph with only a context line -> still silent, exit 1, report unchanged" \
  || no "precheck context-only erroring graph" "prc=$prc rc=$RC plain=$plain out=$OUT"

# 73. Flag grammar: `--explain` and `--precheck` are a leading flag block in either order; a flag
#     after a positional is a usage error, exit 2, no report. With both flags both blocks print and
#     the report after them is unchanged. The --explain fixtures above (cases 46 to 59) stay green.
OUT="$(bash "$LINT" "$ae4" --precheck 2>&1)"; RC=$?
{ [ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "usage" && echo "$OUT" | grep -qF -- "[--explain] [--precheck]" \
  && ! echo "$OUT" | grep -q "node(s) in"; } \
  && ok "--precheck after the root -> usage error, exit 2, no report" || no "--precheck not first" "rc=$RC out=$OUT"
OUT="$(bash "$LINT" --explain "$ae4" --precheck 2>&1)"; RC=$?
{ [ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "usage" && ! echo "$OUT" | grep -q "node(s) in"; } \
  && ok "--precheck after --explain and the root -> usage error, exit 2" || no "--precheck after positional" "rc=$RC out=$OUT"
plain="$(bash "$LINT" "$ae4" 2>&1)"
a="$(bash "$LINT" --explain --precheck "$ae4" 2>&1)"; arc=$?
b="$(bash "$LINT" --precheck --explain "$ae4" 2>&1)"; brc=$?
both(){   # both OUTPUT: the EXPLAIN block, the PRECHECK block, then the plain report, whatever the order
  printf '%s\n' "$1" | grep -q '^EXPLAIN (2 edges):$' && printf '%s\n' "$1" | grep -q '^PRECHECK:$' \
    && printf '%s\n' "$1" | grep -qx 'precheck: silent' \
    && [ "$(printf '%s\n' "$1" | sed '1,/^$/d' | sed '1,/^$/d')" = "$plain" ]
}
{ [ "$arc" -eq 0 ] && [ "$brc" -eq 0 ] && both "$a" && both "$b"; } \
  && ok "--explain --precheck and --precheck --explain both print both blocks, report unchanged" \
  || no "both flags both orders" "arc=$arc a=$a brc=$brc b=$b"
c="$(cd "$ae4" && bash "$LINT" --precheck --explain NODE-008 2>&1)"; crc=$?
{ [ "$crc" -eq 0 ] && echo "$c" | grep -q '^EXPLAIN (1 edges):$' && echo "$c" | grep -q '^PRECHECK:$'; } \
  && ok "--precheck --explain NODE-008 from inside the repo: the ID still scopes --explain" \
  || no "both flags with an ID" "crc=$crc c=$c"

# 74. Reads only committed frontmatter and edges (KD10): a fixture built as a git repo, committed,
#     and cloned to a scratch directory gives a byte-identical PRECHECK block at the same commit.
base="$(mktemp -d)"; d="$base/src"; mkdir -p "$d/graph"
node "$d" THEORY-001.md '---
id: THEORY-001
kind: theory
status: backtest
next_gate: "EXP-001 beats vector-only -> paper_trade"
---
Theory.'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
question: "q?"
result: "+6 pts"
abandon_if: "gain under 2 pts"
edges:
  - {rel: part_of, to: THEORY-001}
---
Complete.'
node "$d" IDEA-001.md '---
id: IDEA-001
kind: idea
status: deferred
reopen_when: "EXP-001 abandoned"
---
Parked.'
( cd "$d" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm fixture ) >/dev/null 2>&1
git clone -q "$d" "$base/clone" >/dev/null 2>&1
src="$(cd "$d" && bash "$LINT" --precheck . 2>&1 | sed -n '/^PRECHECK:$/,/^$/p')"
cln="$(cd "$base/clone" && bash "$LINT" --precheck . 2>&1 | sed -n '/^PRECHECK:$/,/^$/p')"
{ [ -n "$src" ] && [ "$src" = "$cln" ] && printf '%s\n' "$src" | grep -qx "STALE_GATE THEORY-001 EXP-001 complete" \
  && printf '%s\n' "$src" | grep -q '^EXIT_PENDING EXP-001' && printf '%s\n' "$src" | grep -q '^FUTILITY 1 deferred'; } \
  && ok "precheck: a scratch clone at the same commit prints a byte-identical PRECHECK block" \
  || no "precheck clone parity" "src=$src cln=$cln"

echo "---"; echo "graph-lint test: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
