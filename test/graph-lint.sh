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

# 4. dangling wiki edge
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
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "missing wiki file wiki/missing.md"; } \
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

# 12. transitive invalidation: C invalidated, B blocked, A depends_on B but NOT blocked -> error
d="$(newfix)"
node "$d" NODE-C.md '---
id: NODE-C
kind: pipeline_node
status: invalidated
---
Bad retriever.'
node "$d" NODE-B.md '---
id: NODE-B
kind: pipeline_node
status: blocked
edges:
  - {rel: depends_on, to: NODE-C}
---
Correctly blocked.'
node "$d" NODE-A.md '---
id: NODE-A
kind: pipeline_node
status: assumed_working
edges:
  - {rel: depends_on, to: NODE-B}
---
Rests on a blocked node but not blocked itself.'
runlint "$d"
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "NODE-A: depends_on blocked node NODE-B but is not blocked"; } \
  && ok "transitive invalidation (multi-hop) -> error" || no "transitive invalidation" "rc=$RC out=$OUT"
# positive control: block NODE-A too -> whole chain consistent, exit 0
node "$d" NODE-A.md '---
id: NODE-A
kind: pipeline_node
status: blocked
edges:
  - {rel: depends_on, to: NODE-B}
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

echo "---"; echo "graph-lint test: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
