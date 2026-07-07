#!/usr/bin/env bash
# Tier-2 compliance test for opt-in background execution (U2/U3), via headless Claude Code.
# Measures how reliably `background = on` dispatches a subagent (keeping the main thread clean)
# and confirms the default path (`background = off`) stays strictly inline.
#
# COSTS MODEL TOKENS: every iteration is a real `claude -p` run plus any subagent it spawns.
# Keep N small while calibrating; raise it for a real compliance measurement (plan targets ~8/10).
#
# Usage:   bash test/background-integration.sh [N]         # N iterations per op, default 3
# Env:     TENDREL_TEST_MODEL=<model>  to run a cheaper model and cut cost.
#
# Plugin loading: tries --plugin-dir against this repo so the BRANCH code is tested. If dispatch
# is 0 everywhere, the plugin likely did not load that way; fall back to installing from a local
# marketplace (`/plugin marketplace add <repo>` then install) and the enabledPlugins setting the
# fixtures already write, then re-run.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-3}"
MODEL="${TENDREL_TEST_MODEL:-}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mkfix(){ # $1=dir  $2=.research-graph contents
  mkdir -p "$1/graph" "$1/.claude"
  cp "$REPO"/examples/doc-search/graph/*.md "$1/graph/" 2>/dev/null || true
  printf '%s\n' "$2" > "$1/.research-graph"
  printf '{"enabledPlugins":{"tendrel@tendrel":true}}' > "$1/.claude/settings.local.json"
}

# One headless run. Prints "DISPATCH:<0|1> CHARS:<n>" (chars = length of final result text).
run_once(){
  local dir="$1" prompt="$2" out
  out="$(cd "$dir" && claude -p "$prompt" \
        --output-format stream-json --verbose \
        --dangerously-skip-permissions \
        ${MODEL:+--model "$MODEL"} \
        --plugin-dir "$REPO/plugin" 2>/dev/null)"
  local disp chars
  disp=$(printf '%s' "$out" | jq -rs '[.[] | select(.type=="assistant") | .message.content[]?
           | select(.type=="tool_use") | select(.name=="Task" or .name=="Agent")] | length' 2>/dev/null)
  chars=$(printf '%s' "$out" | jq -rs 'last(.[] | select(.type=="result") | .result) // ""' 2>/dev/null | wc -c)
  echo "DISPATCH:$([ "${disp:-0}" -gt 0 ] && echo 1 || echo 0) CHARS:${chars:-0}"
}

echo "== default-path guard: background=off, /tendrel:status must NOT dispatch a subagent =="
mkfix "$T/off" "project = t
background = off"
r=$(run_once "$T/off" "/tendrel:status"); echo "  $r"
echo "$r" | grep -q "DISPATCH:0" && echo "  PASS inline" || echo "  FAIL dispatched under background=off"

echo "== compliance: background=on, N=$N per op =="
mkfix "$T/on" "project = t
background = on"
for op in "/tendrel:status" "/tendrel:seed"; do
  d=0
  for i in $(seq 1 "$N"); do
    r=$(run_once "$T/on" "$op"); echo "  $op run $i: $r"
    echo "$r" | grep -q "DISPATCH:1" && d=$((d+1))
  done
  echo "  ==> $op dispatched $d/$N"
done
echo "Target: high dispatch rate under background=on, zero under background=off."
