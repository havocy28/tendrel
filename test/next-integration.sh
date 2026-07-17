#!/usr/bin/env bash
# Tier-2 contract test for /tendrel:next, via headless Claude Code. Measures the two load-bearing
# rules on REAL generated output, plus a soft negative-grounding check:
#   1. ID-FREE BODY (hard): no graph node ID appears above the "Where this came from" footer.
#      This is the dogfood failure (IDs surfaced inline, judged not human-readable) made into a gate.
#   2. GROUNDED FOOTER (hard): the footer cites >= 1 node and every ID it cites is real (exists in
#      graph/), so proposals are grounded and citations are not hallucinated.
#   3. NEGATIVE GROUNDING (soft, reported): proposals carry "skip X, already ruled out" language.
#
# Slash commands DO fire under `claude -p` (unlike SessionStart hooks), so unlike the autonomy
# harness this contract is fully reachable headlessly. COSTS MODEL TOKENS (one `claude -p` per run).
#
# The node-ID matcher is anchored to tendrel's actual prefixes, so domain terms that look
# ID-shaped (ICD-11, GPT-4) do not false-trigger.
#
# Usage: bash test/next-integration.sh [N]   (N model runs, default 3)
# Env:   TENDREL_TEST_MODEL=<model>  to run a cheaper model and cut cost.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-3}"
case "$N" in (''|*[!0-9]*) echo "N must be a positive integer, got '$N'" >&2; exit 2;; esac
[ "$N" -ge 1 ] || { echo "N must be >= 1, got $N" >&2; exit 2; }
MODEL="${TENDREL_TEST_MODEL:-}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  $2"; fail=$((fail+1)); }

FOOTER_HDR="Where this came from"    # must match the header the skill/command specify (checks.sh guards it)
ID_RE='(EXP|OBS|NODE|THEORY|DEC|IDEA)-[0-9]+'

enable(){ mkdir -p "$1/.claude"; printf '{"enabledPlugins":{"tendrel@tendrel":true}}' > "$1/.claude/settings.local.json"; }
# Fixture: the doc-search example graph. It carries invalidated / blocked / supersedes nodes, the
# exact material the negative-grounding half of a proposal needs. /tendrel:next is read-only, so one
# fixture is reused across runs (no per-run contamination).
mkfix(){ mkdir -p "$1/graph"; cp "$REPO"/examples/doc-search/graph/*.md "$1/graph/"; enable "$1"; }
real_ids(){ for f in "$1"/graph/*.md; do basename "$f" .md; done; }

body_of(){ awk -v h="$FOOTER_HDR" 'index($0,h){exit} {print}'; }     # lines before the footer header
footer_of(){ awk -v h="$FOOTER_HDR" 'index($0,h){f=1} f{print}'; }   # the footer header line onward
body_ids(){ body_of | grep -oE "$ID_RE" | sort -u; }
footer_ids(){ footer_of | grep -oE "$ID_RE" | sort -u; }

FIX="$T/fix"; mkfix "$FIX"
REAL_IDS=" $(real_ids "$FIX" | tr '\n' ' ') "
is_real(){ case "$REAL_IDS" in *" $1 "*) return 0;; *) return 1;; esac; }

# --- Deterministic self-checks (no model): prove each detector actually asserts before we spend
#     tokens. If these fail, the measurement below would be meaningless. ---
CTL_BADBODY='The disease-NER gate is the move next (EXP-001).
'"$FOOTER_HDR"'
- EXP-001: the baseline'
[ -n "$(printf '%s\n' "$CTL_BADBODY" | body_ids)" ] \
  && ok "self-check: inline node ID in the body is detected" \
  || no "self-check: inline node ID in the body is detected" "body-ID detector did not fire"

CTL_HALLUCINATED='Run the gate next; skip more benchmark tuning.
'"$FOOTER_HDR"'
- EXP-999: a node that does not exist'
gbad=""; for id in $(printf '%s\n' "$CTL_HALLUCINATED" | footer_ids); do is_real "$id" || gbad="$gbad $id"; done
[ -n "$gbad" ] && ok "self-check: hallucinated footer citation is detected" \
  || no "self-check: hallucinated footer citation is detected" "grounding detector did not fire"

CTL_CLEAN='Try the reranker next; skip the BM25 fusion, it regressed. ICD-11 codes are unaffected.
'"$FOOTER_HDR"'
- EXP-016: BM25 was gate-rejected'
[ -z "$(printf '%s\n' "$CTL_CLEAN" | body_ids)" ] \
  && ok "self-check: clean body with domain terms (ICD-11, BM25) does not false-trigger" \
  || no "self-check: clean body false-triggers" "domain terms matched the node-ID pattern"

# --- Model arm ---
run_once(){ # $1=dir -> the model's final result text on stdout; empty + rc!=0 on failure
  local dir="$1" out rc
  out=$(cd "$dir" && claude -p "/tendrel:next" \
        --output-format stream-json --verbose --dangerously-skip-permissions \
        ${MODEL:+--model "$MODEL"} --plugin-dir "$REPO/plugin" 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] && return 1
  printf '%s' "$out" | jq -rs 'last(.[] | select(.type=="result") | .result) // ""' 2>/dev/null
}

echo "== /tendrel:next contract, N=$N (fixture: examples/doc-search) =="
bodyfail=0; groundfail=0; neg=0; errs=0
for i in $(seq 1 "$N"); do
  txt="$(run_once "$FIX")" || { echo "  run $i: RUN:ERR (claude exit)"; errs=$((errs+1)); continue; }
  [ -z "$txt" ] && { echo "  run $i: RUN:ERR (no result text)"; errs=$((errs+1)); continue; }
  bids="$(printf '%s' "$txt" | body_ids | tr '\n' ',')"
  fids="$(printf '%s' "$txt" | footer_ids)"
  if [ -n "$bids" ]; then bodyfail=$((bodyfail+1)); bstat="BODY-IDS[$bids]"; else bstat="body-clean"; fi
  gbad=""; for id in $fids; do is_real "$id" || gbad="$gbad $id"; done
  if [ -z "$fids" ]; then groundfail=$((groundfail+1)); gstat="GROUND[empty-footer]"
  elif [ -n "$gbad" ]; then groundfail=$((groundfail+1)); gstat="GROUND[hallucinated:$gbad]"
  else gstat="grounded"; fi
  if printf '%s' "$txt" | grep -qiE 'skip|already ruled|ruled out|do not repeat|don.t repeat'; then
    neg=$((neg+1)); nstat="neg+"; else nstat="neg-"; fi
  echo "  run $i: $bstat $gstat $nstat"
done

echo "  ==> ID-free body $((N-bodyfail))/$N | grounded footer $((N-groundfail))/$N | negative-grounding $neg/$N (soft) | errored $errs/$N"
[ "$errs" -eq 0 ] || no "all $N runs completed" "$errs run(s) errored; the measurement is incomplete and certifies nothing"
[ "$errs" -eq 0 ] && { [ "$bodyfail" -eq 0 ] && ok "ID-free body (hard): $N/$N" || no "ID-free body (hard)" "$bodyfail/$N leaked node IDs into the body"; }
[ "$errs" -eq 0 ] && { [ "$groundfail" -eq 0 ] && ok "grounded footer (hard): $N/$N" || no "grounded footer (hard)" "$groundfail/$N had an empty or hallucinated footer"; }

echo "---"; echo "next-integration: PASS=$pass FAIL=$fail (negative-grounding is reported, not gated)"
[ "$fail" -eq 0 ]
