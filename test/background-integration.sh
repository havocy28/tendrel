#!/usr/bin/env bash
# Tier-2 compliance test for opt-in background execution (U2/U3), via headless Claude Code.
# Measures how reliably `background = on` dispatches a subagent (keeping the main thread clean)
# and confirms the default path (`background = off`) stays strictly inline.
#
# COSTS MODEL TOKENS: every iteration is a real `claude -p` run plus any subagent it spawns.
# Keep N small while calibrating; raise it for a real compliance measurement (plan targets ~8/10).
#
# Usage:   bash test/background-integration.sh [N] [op]
#            N  = iterations per op (default 3)
#            op = all | status | seed | off   (default all)
# Env:     TENDREL_TEST_MODEL=<model>  to run a cheaper model and cut cost.
#
# Fixtures matter: status needs a POPULATED graph (something to regenerate status.md from); seed
# needs PROJECT CONTENT but NO graph yet (an already-populated graph makes seed stay inline by
# design, which is not the background path we are measuring).
#
# Plugin loading: --plugin-dir loads the BRANCH code. If dispatch is 0 everywhere, the plugin did
# not load; fall back to a local-marketplace install plus the enabledPlugins setting the fixtures
# already write, then re-run.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-3}"
OP="${2:-all}"
MODEL="${TENDREL_TEST_MODEL:-}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

enable(){ mkdir -p "$1/.claude"; printf '{"enabledPlugins":{"tendrel@tendrel":true}}' > "$1/.claude/settings.local.json"; }

# status/off fixture: a populated graph
mkgraphfix(){ # $1=dir  $2=.research-graph contents
  mkdir -p "$1/graph"; cp "$REPO"/examples/doc-search/graph/*.md "$1/graph/" 2>/dev/null || true
  printf '%s\n' "$2" > "$1/.research-graph"; enable "$1"
}

# seed fixture: real project content to read, but NO graph/ yet (so seed does the read-and-draft)
mkseedfix(){ # $1=dir  $2=.research-graph contents
  mkdir -p "$1/src"
  cat > "$1/README.md" <<'RM'
# demo-search
A document retrieval service. Components: an ingestion + chunking pipeline, an embedding index,
a vector-only retriever, and an end-to-end answer-quality eval. Recent work: hybrid retrieval
beat vector-only; a cross-encoder reranker experiment is currently running.
RM
  cat > "$1/src/pipeline.py" <<'PY'
def chunk(doc): ...    # 512-token chunks, 64 overlap (DEC-001)
def embed(chunks): ...
def retrieve(q): ...   # vector-only baseline; hybrid variant in progress
PY
  cat > "$1/NOTES.md" <<'NT'
- EXP-001 vector-only nDCG@10 0.61 (baseline)
- EXP-002 hybrid nDCG@10 0.71 (won, supersedes vector-only)
- EXP-003 reranker eval running
- OBS: recall drops on table/figure queries (chunking splits captions)
NT
  printf '%s\n' "$2" > "$1/.research-graph"; enable "$1"
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

compliance(){ # $1=label $2=op $3=fixdir
  local d=0 i r
  for i in $(seq 1 "$N"); do
    r=$(run_once "$3" "$2"); echo "  $2 run $i: $r"
    echo "$r" | grep -q "DISPATCH:1" && d=$((d+1))
  done
  echo "  ==> $2 dispatched $d/$N"
}

if [ "$OP" = "all" ] || [ "$OP" = "off" ]; then
  echo "== default-path guard: background=off, /tendrel:status must NOT dispatch a subagent =="
  mkgraphfix "$T/off" "project = t
background = off"
  r=$(run_once "$T/off" "/tendrel:status"); echo "  $r"
  echo "$r" | grep -q "DISPATCH:0" && echo "  PASS inline" || echo "  FAIL dispatched under background=off"
fi

echo "== compliance: background=on, N=$N =="
if [ "$OP" = "all" ] || [ "$OP" = "status" ]; then
  mkgraphfix "$T/on_status" "project = t
background = on"
  compliance status "/tendrel:status" "$T/on_status"
fi
if [ "$OP" = "all" ] || [ "$OP" = "seed" ]; then
  mkseedfix "$T/on_seed" "project = t
background = on"
  compliance seed "/tendrel:seed" "$T/on_seed"
fi
echo "Target: high dispatch rate under background=on, zero under background=off."
