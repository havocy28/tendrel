#!/usr/bin/env bash
# U6 + U7 — production Stop reconcile hook.
#
# Trigger model A (fire-and-let-the-model-decide): on any turn that ends in a repo with a
# graph/ dir, drive a reconcile; the model no-ops when nothing graph-relevant changed.
# (A Stop hook fires per assistant turn — there is no distinct session-end event — so this
# reconciles after each turn rather than literally once. No-op-when-clean keeps it cheap.)
#
# Two passes, distinguished by a per-session-turn marker (re-entry guard, KTD4):
#   Pass 1 (no marker): snapshot graph/, write marker, emit decision:block -> reconcile.
#   Pass 2 (marker):    the model's reconcile turn has ended -> compare graph/ to the
#                       snapshot, log the reliability signal (graph_diff yes/no), clean up,
#                       allow exit.
# Scope guard: inert unless cwd has a graph/ dir -> safe to leave installed globally.
set -euo pipefail

DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.research-graph-data}"
mkdir -p "$DATA/markers" "$DATA/snapshots"
payload="$(cat || true)"

field() { printf '%s' "$payload" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('$1',''))
except Exception: print('')" 2>/dev/null || true; }

sid="$(field session_id)"; [ -z "$sid" ] && sid="unknown"
cwd="$(field cwd)";        [ -z "$cwd" ] && cwd="$PWD"
graphdir="$cwd/graph"
ts="$(date -Is 2>/dev/null || date)"
marker="$DATA/markers/$sid"
snap="$DATA/snapshots/$sid"

manifest() {  # stable change-fingerprint of graph/*.md (cksum is POSIX, always present)
  if [ -d "$graphdir" ]; then
    find "$graphdir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      cksum "$f"
    done
  fi
}

# Scope guard.
if [ ! -d "$graphdir" ]; then
  printf '%s  [%s]  no graph/ in %s -> allow exit\n' "$ts" "$sid" "$cwd" >> "$DATA/signal.log"
  exit 0
fi

# Pass 2: the reconcile turn finished. Measure, log signal, clean up, allow exit.
if [ -f "$marker" ]; then
  after="$(manifest)"
  before="$(cat "$snap" 2>/dev/null || true)"
  if [ "$after" != "$before" ]; then diff="yes"; else diff="no"; fi
  printf '%s  [%s]  reconcile complete  graph_diff=%s  -> allow exit\n' "$ts" "$sid" "$diff" >> "$DATA/signal.log"
  rm -f "$marker" "$snap"
  exit 0
fi

# Pass 1: snapshot, mark (before block), drive the reconcile.
manifest > "$snap"
: > "$marker"
printf '%s  [%s]  firing block -> reconcile requested (%s)\n' "$ts" "$sid" "$graphdir" >> "$DATA/signal.log"

cat <<'JSON'
{"decision":"block","reason":"Reconcile this project's research graph before stopping, per the research-graph skill: update graph/ node statuses, results, and edges to match what this session actually did; if a pipeline_node was built or invalidated, trace and report what's affected; append any friction about the system to the friction log (tag confidently-wrong vs incomplete) and note the reconstruction gap if you had to reconstruct much at close. If nothing graph-relevant happened, make no changes and stop."}
JSON
exit 0
