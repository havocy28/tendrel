#!/usr/bin/env bash
# Tier-2 compliance test for the write-side provenance contract, via headless Claude Code.
# The contract (SKILL.md, "Recording a number"): when a node records a numeric result, the number
# is read out of the artifact that produced it, not restated from conversation, and that artifact
# is named in `provenance:`.
#
# Experiment: the fixture carries results/exp-003-reranker.md holding the PRECISE figures
# (nDCG@10 0.7412 vs 0.7089). The prompt narrates ROUNDED figures (0.74 vs 0.71) and names the
# file. A node that ends up holding 0.74 transcribed the chat; one holding 0.7412 read the
# artifact. `reconcile = auto` is set only to maximize writes; the contract itself is
# key-independent (live logging happens under every value of the reconcile key).
#
#   1. RUN (hard): every iteration must complete with a result event, or the measurement is void.
#   2. WRITES (hard): at least one run must write EXP-003, or the contract was never observable.
#   3. PROVENANCE (hard, rate): of the runs that wrote, at least one must declare `provenance:`
#      naming the artifact. Markdown contracts comply at a rate, not always; fail only on zero.
#   4. ARTIFACT PRECISION (hard, rate): of the runs that wrote, at least one must hold 0.7412,
#      the artifact's figure, rather than the 0.74 narrated in chat. This is the only signal that
#      the file was actually read: the prompt names the artifact, so a provenance line can be
#      produced by echoing the prompt. Measured 2026-09-01, N=5: writes 5/5, provenance 5/5,
#      artifact-precise 5/5.
#
# Both detectors read FRONTMATTER only (PROV) or the whole node (PRECISE), and are covered by
# deterministic self-checks below so the harness cannot false-pass on its own regex.
#
# Same headless caveat as the other contract harnesses: `claude -p` does not fire SessionStart
# hooks, so this measures the skill-activation path only.
#
# COSTS MODEL TOKENS: every iteration is a real `claude -p` run.
#
# Usage:   bash test/provenance-integration.sh [N]     (N = iterations, default 3)
# Env:     TENDREL_TEST_MODEL=<model>  to run a cheaper model and cut cost.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-3}"
case "$N" in (''|*[!0-9]*) echo "N must be a positive integer, got '$N'" >&2; exit 2;; esac
[ "$N" -ge 1 ] || { echo "N must be >= 1, got $N" >&2; exit 2; }
MODEL="${TENDREL_TEST_MODEL:-}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

enable(){ mkdir -p "$1/.claude"; printf '{"enabledPlugins":{"tendrel@tendrel":true}}' > "$1/.claude/settings.local.json"; }

mkfix(){ # $1=dir
  mkdir -p "$1/graph" "$1/results"; cp "$REPO"/examples/doc-search/graph/*.md "$1/graph/"
  cat > "$1/results/exp-003-reranker.md" <<'RS'
# EXP-003 reranker eval, full record

run: 2026-07-01
n_queries: 500

| metric | reranked | hybrid baseline |
|---|---|---|
| nDCG@10 | 0.7412 | 0.7089 |
| recall@50 | 0.9137 | 0.9002 |
RS
  printf 'project = t\nreconcile = auto\n' > "$1/.research-graph"; enable "$1"
}

PROMPT='The reranker eval just finished: EXP-003 came back with nDCG@10 around 0.74, clearly
beating hybrid retrieval at about 0.71. The full numbers are in results/exp-003-reranker.md.
Good stopping point, I am done for today.'

run_once(){ # $1=dir -> prints "RUN:ERR" or "WRITES:<0|1> PROV:<0|1> PRECISE:<0|1>"
  local dir="$1" before after out rc node prov precise
  before=$(md5sum "$dir/graph/EXP-003.md")
  out=$(cd "$dir" && claude -p "$PROMPT" \
      --output-format stream-json --verbose \
      --dangerously-skip-permissions \
      ${MODEL:+--model "$MODEL"} \
      --plugin-dir "$REPO/plugin" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | grep -q '"type":"result"'; then
    echo "RUN:ERR"; return
  fi
  after=$(md5sum "$dir/graph/EXP-003.md")
  if [ "$before" = "$after" ]; then echo "WRITES:0 PROV:0 PRECISE:0"; return; fi
  node=$(cat "$dir/graph/EXP-003.md")
  echo "WRITES:1 PROV:$(detect_prov "$node") PRECISE:$(detect_precise "$node")"
}

# Detectors. PROV looks only inside the frontmatter and only at the provenance key, in the inline
# form (`provenance: [.., results/x.md, ..]`), the scalar form, or the block form (`- results/x.md`
# lines directly under a bare `provenance:` line). A body bullet naming the file is not a
# declaration and must not count.
detect_prov(){ # $1=node text -> 0|1
  printf '%s\n' "$1" | awk '
    NR==1 && /^---$/ {fm=1; next}
    fm && /^---$/ {exit}
    !fm {next}
    /^provenance[ \t]*:/ { inblock=0
      if ($0 ~ /results\/exp-003-reranker\.md/) {hit=1}
      else if ($0 ~ /^provenance[ \t]*:[ \t]*$/) {inblock=1}
      next }
    inblock && /^[ \t]+-[ \t]*results\/exp-003-reranker\.md/ {hit=1}
    inblock && /^[^ \t]/ {inblock=0}
    END {print (hit ? 1 : 0)}'
}
detect_precise(){ printf '%s' "$1" | grep -q '0\.7412' && echo 1 || echo 0; }

# Deterministic self-checks: the harness's own detectors, on nodes with a known answer. A wrong
# detector would otherwise be measured as an agent behavior.
sc_fail=0
sc(){ [ "$2" = "$3" ] && echo "  selfcheck ok: $1" || { echo "  selfcheck FAIL: $1 (got $2, want $3)"; sc_fail=1; }; }
sc "inline provenance -> PROV 1" "$(detect_prov $'---\nid: EXP-003\nprovenance: [results/exp-003-reranker.md]\n---\nbody')" 1
sc "block provenance -> PROV 1" "$(detect_prov $'---\nid: EXP-003\nprovenance:\n  - results/exp-003-reranker.md\nedges:\n  - {rel: part_of, to: THEORY-001}\n---\nbody')" 1
sc "body bullet only -> PROV 0" "$(detect_prov $'---\nid: EXP-003\nresult: \"0.74\"\n---\n- results/exp-003-reranker.md')" 0
sc "other key naming the file -> PROV 0" "$(detect_prov $'---\nid: EXP-003\nconfig: {source: results/exp-003-reranker.md}\n---\nbody')" 0
sc "artifact figure -> PRECISE 1" "$(detect_precise $'---\nresult: \"nDCG@10 0.7412\"\n---')" 1
sc "rounded figure -> PRECISE 0" "$(detect_precise $'---\nresult: \"nDCG@10 0.74\"\n---')" 0
[ "$sc_fail" -eq 0 ] || { echo "detector self-checks failed; the measurement would be meaningless."; exit 1; }

w=0; p=0; x=0; e=0
echo "== provenance contract: rounded figures in chat, precise figures on disk, N=$N =="
for i in $(seq 1 "$N"); do
  d="$T/run_$i"; mkfix "$d"
  r=$(run_once "$d"); echo "  run $i: $r"
  echo "$r" | grep -q "RUN:ERR"   && e=$((e+1))
  echo "$r" | grep -q "WRITES:1"  && w=$((w+1))
  echo "$r" | grep -q "PROV:1"    && p=$((p+1))
  echo "$r" | grep -q "PRECISE:1" && x=$((x+1))
done
echo "  ==> wrote EXP-003 in $w/$N runs; declared provenance in $p/$w writes; artifact-precise figure in $x/$w writes ($e errored)"

fail=0
if [ "$e" -gt 0 ]; then echo "  FAIL: $e/$N runs errored; the measurement is incomplete and certifies nothing."; fail=1; fi
if [ "$e" -eq 0 ] && [ "$w" -eq 0 ]; then echo "  FAIL: no run wrote EXP-003; the contract was never observable."; fail=1; fi
if [ "$w" -gt 0 ] && [ "$p" -eq 0 ]; then echo "  FAIL: nodes were written but none declared provenance; the contract does not trigger."; fail=1; fi
if [ "$w" -gt 0 ] && [ "$x" -eq 0 ]; then echo "  FAIL: nodes were written but none holds the artifact's figure 0.7412; numbers were transcribed from chat."; fail=1; fi
echo "Targets: provenance declared in >0 writes (hard); artifact-precise figure in >0 writes (hard)."
[ "$fail" -eq 0 ]
