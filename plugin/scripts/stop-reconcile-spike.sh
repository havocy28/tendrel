#!/usr/bin/env bash
# U1 + U2 spike (combined). THE load-bearing gate for the whole plan.
#
# Question: can a Stop hook's {"decision":"block","reason":...} actually drive the
# model to EDIT a graph/ file (not merely respond)?
#
# Safe-by-scope: this hook only acts when the current repo has graph/EXP-001.md with
# `status: running`. Everywhere else (including your planning session) it logs "nothing
# to reconcile" and allows exit — so it's safe to install globally. The status guard also
# prevents a loop: once the reconcile flips status to `complete`, the hook goes inert.
#
# Evidence it produces (in $CLAUDE_PLUGIN_DATA, fallback ~/.research-graph-data):
#   signal.log  -> "firing block" means the hook fired (U1 wiring OK)
#   graph/EXP-001.md flipping running->complete means the block drove an edit (U2 PASS)
set -euo pipefail

DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.research-graph-data}"
mkdir -p "$DATA/markers"
payload="$(cat || true)"

field() {  # field <key> : extract a top-level string from the stdin JSON payload
  printf '%s' "$payload" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('$1',''))
except Exception: print('')" 2>/dev/null || true
}

sid="$(field session_id)"; [ -z "$sid" ] && sid="unknown"
cwd="$(field cwd)"; [ -z "$cwd" ] && cwd="$PWD"
target="$cwd/graph/EXP-001.md"
ts="$(date -Is 2>/dev/null || date)"

# Scope + completion guard: only act where the fixture exists AND is still 'running'.
if [ ! -f "$target" ] || ! grep -Eq '^status:[[:space:]]*running' "$target"; then
  printf '%s  [%s]  nothing to reconcile in %s -> allow exit\n' "$ts" "$sid" "$cwd" >> "$DATA/signal.log"
  exit 0
fi

# Per-session re-entry guard (KTD4): marker written BEFORE block, checked FIRST.
marker="$DATA/markers/$sid"
if [ -f "$marker" ]; then
  printf '%s  [%s]  marker present -> allow exit (one pass already done)\n' "$ts" "$sid" >> "$DATA/signal.log"
  exit 0
fi

printf '%s  [%s]  firing block -> reconcile requested (%s)\n' "$ts" "$sid" "$target" >> "$DATA/signal.log"
: > "$marker"

cat <<'JSON'
{"decision":"block","reason":"Research-graph reconcile (spike): open graph/EXP-001.md, change its `status:` frontmatter from `running` to `complete`, and append one line to the body noting that this session reconciled it. This verifies the Stop hook can drive a graph edit. Make only that edit, then stop."}
JSON
exit 0
