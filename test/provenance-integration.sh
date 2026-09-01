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
#   4. ARTIFACT PRECISION (informational): how many written nodes hold 0.7412 rather than 0.74.
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
  prov=0; printf '%s' "$node" | grep -qE '^provenance:.*results/exp-003-reranker\.md|^\s*-\s*results/exp-003-reranker\.md' && prov=1
  precise=0; printf '%s' "$node" | grep -q '0\.7412' && precise=1
  echo "WRITES:1 PROV:$prov PRECISE:$precise"
}

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
echo "Targets: provenance declared in >0 writes (hard); artifact-precise figure is informational."
[ "$fail" -eq 0 ]
