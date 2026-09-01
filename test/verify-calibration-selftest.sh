#!/usr/bin/env bash
# Known-answer tests for plugin/scripts/graph-calibrate.sh (the /tendrel:calibrate report).
#
# The calibration harness exists to stop the verify design being argued from hand measurements.
# That only works if the harness itself is right, so every fixture here has an answer known by
# construction and the test asserts the exact reported number. A harness nobody has tested is the
# same failure it was built to prevent, one level up.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CAL="$REPO/plugin/scripts/graph-calibrate.sh"
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
expect "narrow source seeds 2 of 3"      "$(num 'seedable from provenance:/config:/Full record:')" "2"
expect "wide source seeds 3 of 3"        "$(num 'seedable incl. inline body paths')" "3"
expect "narrow residual is 1"            "$(num 'residual backlog, narrow source')" "1"
expect "wide residual is 0"              "$(num 'residual backlog, wide source')" "0"

# a node whose ONLY citation is provenance: (the key this release introduces) is seedable in the
# narrow tier, and its claim matches inside the declared artifact even though the artifact lives
# outside the PATH_RX directory prefixes (out/ is not results/).
d="$(newfix)"
art "$d" out/run7.txt 'auc 0.8123'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
result: "auc 0.8123"
provenance: [out/run7.txt]
---
No inline path here.'
runcal "$d"
expect "provenance-only node counted as declaring" "$(num 'nodes declaring provenance: paths')" "1"
expect "provenance-only node seeds the narrow tier" "$(num 'seedable from provenance:/config:/Full record:')" "1"
expect "provenance-only node seeds the wide tier"   "$(num 'seedable incl. inline body paths')" "1"
{ echo "$OUT" | grep -m1 'narrow (config:/Full record:) *scripts searched' | grep -q 'unmatched *0/1'; } \
  && ok "claim found in the provenance-declared artifact" || no "provenance artifact searched" "$OUT"

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

# ---------------------------------------------------------------- 9. residue classifier
# rounding-recoverable: artifact holds 1.19698, node claims 1.20 -> rounds to it at 2dp.
d="$(newfix)"
art "$d" results/a.txt 'ratio 1.19698 measured'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
The ratio was 1.20 per `results/a.txt`.'
runcal "$d"
expect "rounding-recoverable detected"  "$(num 'rounding-recoverable')" "1"
expect "not counted as nowhere"         "$(num 'nowhere-in-repo')" "0"

# declared-wrong: the number lives in a DIFFERENT repo file than the one declared.
d="$(newfix)"
art "$d" results/a.txt 'unrelated 9.8765'
art "$d" results/b.txt 'the value 0.4444 lives here'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
Claim 0.4444 per `results/a.txt`.'
runcal "$d"
expect "declared-wrong detected"        "$(num 'declared-wrong')" "1"
expect "one candidate file bucket"      "$(num '1-3 candidate files')" "1"

# nowhere-in-repo: a derived number present in no artifact at all.
d="$(newfix)"
art "$d" results/a.txt 'numerator 0.1611 denominator 0.0377'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
That is 4.27x worse, i.e. 4.2732 per `results/a.txt`.'
runcal "$d"
expect "derived number is nowhere"      "$(num 'nowhere-in-repo')" "1"
expect "not called declared-wrong"      "$(num 'declared-wrong')" "0"
expect "not called rounding-recoverable" "$(num 'rounding-recoverable')" "0"

# a matched claim contributes no residue at all
d="$(newfix)"
art "$d" results/a.txt 'value 0.5555 exact'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
Claim 0.5555 per `results/a.txt`.'
runcal "$d"
expect "matched claim leaves no residue" "$(num 'unmatched claims at best settings')" "0"

# a hedged unmatched claim is excluded from the residue
d="$(newfix)"
art "$d" results/a.txt 'value 0.5555 exact'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
Claim 0.5555 and roughly 0.9999 per `results/a.txt`.'
runcal "$d"
expect "hedged claim excluded from residue" "$(num 'unmatched claims at best settings')" "0"

# table-line context is reported as an overlapping cross-cut, not a bucket
d="$(newfix)"
art "$d" results/a.txt 'nothing useful'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
See `results/a.txt`:
    alpha   0.7777'
runcal "$d"
expect "table-line residue flagged"  "$(num 'on a table/indented line')" "1"
expect "and still bucketed once"     "$(num 'unmatched claims at best settings')" "1"

# attribution context detected
d="$(newfix)"
art "$d" results/a.txt 'nothing useful'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
This line first read 0.8888, which was corrected. See `results/a.txt`.'
runcal "$d"
expect "attribution sentence flagged" "$(num 'in an attribution/supersession sentence')" "1"

# ---------------------------------------------------------------- 10-11. null test / suggestions
# Two nodes. A's claim 0.50 is absent from A's artifact but B's artifact holds 0.5012, which rounds
# to it -- a coincidental rounding pass against an artifact that did not produce the number.
d="$(newfix)"
art "$d" results/a.txt 'A holds 0.7777'
art "$d" results/b.txt 'B holds 0.5012'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
Claim 0.50 per `results/a.txt`.'
node "$d" EXP-002.md '---
id: EXP-002
kind: experiment
status: complete
---
Claim 0.7777 per `results/b.txt`.'
runcal "$d"
expect "null test counts both nodes claims" "$(num 'claims tested against a NON-producing artifact')" "2"
expect "coincidental rounding pass detected" "$(num 'additional pass under precision-aware')" "1"

# Exact coincidental pass: A claims 0.7777, B's artifact literally holds 0.7777.
d="$(newfix)"
art "$d" results/a.txt 'nothing'
art "$d" results/b.txt 'B holds 0.7777'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
Claim 0.7777 per `results/a.txt`.'
node "$d" EXP-002.md '---
id: EXP-002
kind: experiment
status: complete
---
Claim 0.1234 per `results/b.txt`.'
runcal "$d"
expect "exact coincidental pass detected" "$(num 'pass under exact matching')" "1"

# Suggestion precision: the number lives in exactly one repo file, which is the declared one.
d="$(newfix)"
art "$d" results/a.txt 'unique value 0.8642 here'
node "$d" EXP-001.md '---
id: EXP-001
kind: experiment
status: complete
---
Claim 0.8642 per `results/a.txt`.'
runcal "$d"
capline="$(echo "$OUT" | grep -m1 '^  cap 1:')"
expect "cap 1 fires on the unique holder"  "$(echo "$capline" | grep -oE 'fires on +[0-9]+' | grep -oE '[0-9]+')" "1"
expect "cap 1 precision is 100%"           "$(echo "$capline" | grep -oE 'precision +[0-9.]+%' | grep -oE '[0-9.]+')" "100.0"

echo
echo "graph-calibrate selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
