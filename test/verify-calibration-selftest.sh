#!/usr/bin/env bash
# Known-answer tests for test/verify-calibration.sh.
#
# The calibration harness exists to stop the verify design being argued from hand measurements.
# That only works if the harness itself is right, so every fixture here has an answer known by
# construction and the test asserts the exact reported number. A harness nobody has tested is the
# same failure it was built to prevent, one level up.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CAL="$REPO/test/verify-calibration.sh"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  $2"; fail=$((fail+1)); }

newfix(){ local d; d="$(mktemp -d)"; mkdir -p "$d/graph" "$d/results" "$d/scripts" "$d/work"; echo "$d"; }
node(){ printf '%s\n' "$3" > "$1/graph/$2"; }
art(){ mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; }
runcal(){ OUT="$(bash "$CAL" "$1" 2>&1)"; RC=$?; }
# field <label-prefix> -> the last whitespace-separated token on the first matching line
field(){ echo "$OUT" | grep -m1 -- "$1" | tr -s ' ' | sed 's/[[:space:]]*$//' | awk '{print $NF}'; }
# num <label-prefix> -> first integer after the colon
num(){ echo "$OUT" | grep -m1 -- "$1" | sed 's/.*: *//' | grep -oE '^[0-9]+'; }
expect(){ # expect <desc> <actual> <wanted>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got '$2', want '$3'"; fi
}

# ---------------------------------------------------------------- 0. not scaffolded
d="$(mktemp -d)"
runcal "$d"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "not scaffolded\|nothing to measure"; } \
  && ok "unscaffolded repo exits 0 with a message" || no "unscaffolded repo" "rc=$RC out=$OUT"

# ---------------------------------------------------------------- 1. claim extraction / surface
# EXP-001: result: has 1 qualifying number; body has 2. Nothing else qualifies.
#   0.1234 (result:), 0.5678 (body), 0.9999 (body)
#   1.5 is one-decimal -> not a claim. 2026 and 42 are integers -> not claims.
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
result: "measured 0.1234 exactly"
---
Body says 0.5678 plainly.
It also says 0.9999 plainly.
Ignore 1.5 and 2026 and 42.'
runcal "$d"
expect "whole-node claim count is 3"        "$(num 'qualifying numbers, whole node')" "3"
expect "result:-only claim count is 1"      "$(num 'qualifying numbers, result: only')" "1"
expect "claim-bearing nodes, whole = 1"     "$(num 'claim-bearing nodes, whole-node rule')" "1"
expect "one-decimal counted separately = 1" "$(num 'one-decimal numbers, whole node')" "1"

# ---------------------------------------------------------------- 2. hedge scope, the P0 case
# One sentence, two numbers. Only 0.7777 is adjacently hedged. 0.8888 is exempted under
# same-sentence scope purely because "roughly" governs the OTHER number -> the fail-open gap.
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
We saw roughly 0.7777 and then 0.8888 in the same sentence.'
runcal "$d"
expect "sentence scope exempts both"   "$(num 'same-sentence scope, full marker list')" "2"
expect "adjacent scope exempts one"    "$(num 'adjacent-token scope, full marker list')" "1"
expect "fail-open gap is exactly 1"    "$(num 'fail-open gap')" "1"

# under/over are ordinary prose, not hedges: neither number is adjacently hedged.
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
Averaged over 10 runs the value 0.4321 sat under the 0.60 floor.'
runcal "$d"
expect "under/over do not adjacently hedge" "$(num 'adjacent-token scope, full marker list')" "0"
expect "but they do sentence-hedge"         "$(num 'same-sentence scope, full marker list')" "2"
expect "trimmed marker list drops them"     "$(num 'same-sentence scope, no under/over')" "0"

# tilde-prefixed numbers count as hedged adjacently
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
The rate is ~0.5500 here.'
runcal "$d"
expect "tilde prefix hedges adjacently" "$(num 'adjacent-token scope, full marker list')" "1"

# table lines are counted as having no sentence boundary
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
Results:
    alpha   0.1111
    beta    0.2222'
runcal "$d"
expect "indented table numbers flagged" "$(num 'numbers on table/indented lines')" "2"

# ---------------------------------------------------------------- 3. seed sources
# Three claim-bearing nodes, one per citation convention.
d="$(newfix)"
art "$d" results/a.txt 'value 0.1111'
art "$d" results/b.txt 'value 0.2222'
art "$d" results/c.txt 'value 0.3333'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
config: {script; results/a.txt}
---
Claim 0.1111 here.'
node "$d" EXP-002.md '---
id: EXP-002
kind: experiment
status: complete
---
Claim 0.2222 here.
Full record: results/b.txt'
node "$d" EXP-003.md '---
id: EXP-003
kind: experiment
status: complete
---
Claim 0.3333 as recorded in `results/c.txt` inline.'
runcal "$d"
expect "config: path counted"            "$(num "whose config: actually names a path")" "1"
expect "Full record: path counted"       "$(num 'nodes carrying a "Full record:" path')" "1"
expect "narrow source seeds 2 of 3"      "$(num 'seedable from config:/Full record:')" "2"
expect "wide source seeds 3 of 3"        "$(num 'seedable incl. inline body paths')" "3"
expect "narrow residual is 1"            "$(num 'residual backlog, narrow source')" "1"
expect "wide residual is 0"              "$(num 'residual backlog, wide source')" "0"

# a cited path that does not resolve must not count as seedable
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
Claim 0.4444 from `results/missing.txt`.'
runcal "$d"
expect "unresolving path is not seedable" "$(num 'seedable incl. inline body paths')" "0"

# ---------------------------------------------------------------- 4. match rules, the two P0s
# P0-A boundary anchoring: artifact holds 0.9487862, node claims 0.94. Raw substring finds it
# (wrong); anchored does not (right).
d="$(newfix)"
art "$d" results/g.txt 'p_wald 0.9487862'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
The omnibus was 0.94 per `results/g.txt`.'
runcal "$d"
expect "raw substring wrongly matches"   "$(echo "$OUT" | grep -m1 'raw substring' | grep -oE '[0-9]+/[0-9]+')" "1/1"
expect "anchored correctly rejects"      "$(echo "$OUT" | grep -m1 'boundary-anchored' | grep -oE '[0-9]+/[0-9]+')" "0/1"

# P0-B scientific notation: artifact holds 9.487862e-01, node claims 0.9487862.
# Anchored alone fails; anchored + sci-notation recovers it.
d="$(newfix)"
art "$d" results/g.txt 'p_wald 9.487862e-01'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
The omnibus was 0.9487862 per `results/g.txt`.'
runcal "$d"
expect "anchored alone misses sci-notation" "$(echo "$OUT" | grep -m1 'boundary-anchored' | grep -oE '[0-9]+/[0-9]+')" "0/1"
expect "sci-notation canonicalization recovers it" "$(echo "$OUT" | grep -m1 'anchored + sci' | grep -oE '[0-9]+/[0-9]+')" "1/1"

# Thousands separators normalize. NOTE: KTD6's own example (`137,215` matching `137215`) can never
# occur -- 137,215 is an integer and KTD4 excludes integers, so it is never extracted as a claim.
# Normalization is only reachable for separator-bearing numbers that also carry >=2 decimals.
d="$(newfix)"
art "$d" results/g.txt 'value 1234.56 recorded'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
We measured 1,234.56 per `results/g.txt`.'
runcal "$d"
expect "thousands separators normalized" "$(echo "$OUT" | grep -m1 'anchored + sci' | grep -oE '[0-9]+/[0-9]+')" "1/1"

# an integer with separators is not a claim at all
d="$(newfix)"
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
We kept 137,215 sites.'
runcal "$d"
expect "separator-bearing integer is not a claim" "$(num 'qualifying numbers, whole node')" "0"

# ---------------------------------------------------------------- 5. backlog definitions
# A = claim-bearing without provenance:. B = claim-bearing citing no resolving path.
# EXP-001 cites a resolving path -> in A, not in B. EXP-002 cites nothing -> in A and B.
d="$(newfix)"
art "$d" results/a.txt 'value 0.1111'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
Claim 0.1111 from `results/a.txt`.'
node "$d" EXP-002.md '---
id: EXP-002
kind: experiment
status: complete
---
Claim 0.2222 from nowhere.'
runcal "$d"
expect "A counts both"        "$(num 'A. verify backlog')" "2"
expect "B counts only one"    "$(num 'B. crude scan')" "1"
expect "overlap is 1"         "$(num 'overlap')" "1"

# a node that DOES declare provenance: leaves the backlog
d="$(newfix)"
art "$d" results/a.txt 'value 0.1111'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
provenance:
  - results/a.txt
---
Claim 0.1111 here.'
runcal "$d"
expect "declared node counted"     "$(num 'nodes declaring provenance:')" "1"
expect "declared node not backlog" "$(num 'A. verify backlog')" "0"

# ---------------------------------------------------------------- 6. script class
# A cited .py is detected by extension, not by an executable bit or shebang -- the corpus's
# scripts carry neither.
d="$(newfix)"
art "$d" scripts/k9.py 'THRESHOLD = 0.0084'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
Threshold 0.0084 per `scripts/k9.py`.'
chmod -x "$d/scripts/k9.py" 2>/dev/null || true
runcal "$d"
skipped="$(echo "$OUT"  | grep -m1 'wide .*scripts skipped'  | grep -oE 'unmatched +[0-9]+' | grep -oE '[0-9]+')"
searched="$(echo "$OUT" | grep -m1 'wide .*scripts searched' | grep -oE 'unmatched +[0-9]+' | grep -oE '[0-9]+')"
expect "skipping the script leaves the claim unmatched" "$skipped" "1"
expect "searching the script matches it (false verify)" "$searched" "0"

# ---------------------------------------------------------------- 7. read-only guarantee
d="$(newfix)"
art "$d" results/a.txt 'value 0.1111'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
Claim 0.1111 from `results/a.txt`.'
before="$(find "$d" -type f -exec md5sum {} \; | sort | md5sum)"
runcal "$d" >/dev/null
after="$(find "$d" -type f -exec md5sum {} \; | sort | md5sum)"
expect "harness writes nothing" "$before" "$after"

# ---------------------------------------------------------------- 8. determinism
d="$(newfix)"
art "$d" results/a.txt 'value 0.1111'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
Claim 0.1111 and 0.2222 from `results/a.txt`.'
runcal "$d"; first="$OUT"
runcal "$d"; second="$OUT"
expect "two runs agree" "$( [ "$first" = "$second" ] && echo same || echo differs )" "same"

echo
echo "verify-calibration selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
