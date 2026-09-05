#!/usr/bin/env bash
# Tier-2 compliance test for the write-moment edge review, via headless Claude Code.
# The contract (SKILL.md, "Linking to another node" and "The reconcile sweep", step 1): before
# writing the first edge to a target, the agent reads that target's first body line; after writing
# or changing edges and before ending the turn, it runs `graph-lint.sh --explain` on the touched
# nodes and reviews each rendered line, correcting any edge whose target reads wrong.
#
# Experiment: the fixture is the doc-search example graph plus ONE decoy, EXP-004. The decoy's ID,
# filename, and frontmatter (question, config, result) share the prompt's surface vocabulary with
# the intended target EXP-002 (hybrid keyword+vector versus vector-only, nDCG@10, 200 queries), and
# its `question` matches the prompt's wording at least as well as the target's does. Only the first
# body lines disagree: EXP-002 says hybrid wins clearly, EXP-004 says the two tie within noise. The
# prompt narrates a finding BY MEANING (the run where hybrid came out clearly ahead was confounded
# by a leaked BM25 corpus), never by node ID, and asks that the earlier experiment be marked
# invalidated by it. An agent that reads the candidates links EXP-002; one that guesses from a grep
# hit or a filename can land on EXP-004. `reconcile = auto` is set only to maximize writes; the
# contract itself is key-independent (the read-before-linking and explain-review habits apply under
# every value of the reconcile key).
#
#   1. RUN (hard): every iteration must complete with a result event, or the measurement is void.
#   2. WRITES (hard): at least one run must change graph/, or the contract was never observable.
#   3. TARGET_OK (hard, rate): of the runs that wrote, at least one must have put an
#      `invalidated_by` edge on EXP-002 and none on the decoy. This is the outcome that shows the
#      target was read rather than guessed: reading is proven by outcome, not by tool trace.
#   4. NO_MUTUAL (reported, rate): of the runs that wrote, how many left no reversed pair. Measured
#      by running the lint read-only and looking for its mutual-edge error, so the harness reuses
#      the deterministic check instead of carrying a second regex.
#   5. EXPLAIN_RUN (reported, rate): of the runs that wrote, how many ran a Bash command containing
#      `--explain` whose paired tool_result shows the lint rendered edges (`EXPLAIN (`). Counted
#      from the assistant's tool_use blocks, each paired to its result by id: the skill text the
#      agent loads also contains the string, so a tool_result alone must not count as a review,
#      and a no-op invocation (flag not first, wrong cwd) prints usage or "no graph/ directory"
#      and is not a review either.
#
# Rates 4 and 5 are reported, never asserted; a headless rate is a floor. If EXPLAIN_RUN is low,
# check that the review sentence reached the model before rewording it.
#
# All three detectors are covered by deterministic self-checks below so the harness cannot
# false-pass on its own regex; `--selfcheck-only` runs those and exits before any model call.
#
# Same headless caveat as the other contract harnesses: `claude -p` does not fire SessionStart
# hooks, so this measures the skill-activation path only.
#
# Measured 2026-09-04, N=5: writes 5/5, TARGET_OK 5/5, NO_MUTUAL 5/5, EXPLAIN_RUN 5/5, 0 errored.
#
# COSTS MODEL TOKENS: every iteration is a real `claude -p` run.
#
# Usage:   bash test/edge-review-integration.sh [N]     (N = iterations, default 3)
#          bash test/edge-review-integration.sh --selfcheck-only   (detector checks only, no model)
# Env:     TENDREL_TEST_MODEL=<model>  to run a cheaper model and cut cost.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SELFCHECK_ONLY=0
if [ "${1:-}" = "--selfcheck-only" ]; then SELFCHECK_ONLY=1; shift; fi
N="${1:-3}"
case "$N" in (''|*[!0-9]*) echo "N must be a positive integer, got '$N'" >&2; exit 2;; esac
[ "$N" -ge 1 ] || { echo "N must be >= 1, got $N" >&2; exit 2; }
MODEL="${TENDREL_TEST_MODEL:-}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
LINT="$REPO/plugin/scripts/graph-lint.sh"
TARGET=EXP-002   # the experiment the narrated finding undermines
DECOY=EXP-004    # same vocabulary in its frontmatter, a different claim in its first body line

enable(){ mkdir -p "$1/.claude"; printf '{"enabledPlugins":{"tendrel@tendrel":true}}' > "$1/.claude/settings.local.json"; }

mkfix(){ # $1=dir
  mkdir -p "$1/graph"; cp "$REPO"/examples/doc-search/graph/*.md "$1/graph/"
  cat > "$1/graph/EXP-004.md" <<'ND'
---
id: EXP-004
kind: experiment
status: complete
question: "Does hybrid keyword+vector beat vector-only on the held-out eval set?"
config: {retriever: hybrid-bm25+vector, k: 10, n: 200, queries: held-out}
result: "nDCG@10 0.70 vs 0.69"
edges:
  - {rel: part_of, to: THEORY-001}
---
Hybrid and vector-only tie within noise on the held-out queries; no clear winner.
The BM25 corpus for this run never contained the held-out gold passages.
ND
  printf 'project = t\nreconcile = auto\n' > "$1/.research-graph"; enable "$1"
}

PROMPT='Bad news on the retrieval comparison. While rebuilding the BM25 side of the hybrid index
today we found that the corpus it was built over still contained the gold passages for the eval
queries, so the run where hybrid retrieval came out clearly ahead of vector-only was confounded:
the keyword side was partly matching the answers rather than retrieving them. Please record this
as a new observation in the graph and mark that earlier experiment as invalidated by it. Good
stopping point, I am done for today.'

graph_hash(){ (cd "$1/graph" && md5sum -- *.md | md5sum); }

run_once(){ # $1=dir -> prints "RUN:ERR" or "WRITES:<0|1> TARGET_OK:<0|1> NO_MUTUAL:<0|1> EXPLAIN_RUN:<0|1>"
  local dir="$1" before after out rc
  before=$(graph_hash "$dir")
  out=$(cd "$dir" && claude -p "$PROMPT" \
      --output-format stream-json --verbose \
      --dangerously-skip-permissions \
      ${MODEL:+--model "$MODEL"} \
      --plugin-dir "$REPO/plugin" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | grep -q '"type":"result"'; then
    echo "RUN:ERR"; return
  fi
  after=$(graph_hash "$dir")
  if [ "$before" = "$after" ]; then echo "WRITES:0 TARGET_OK:0 NO_MUTUAL:0 EXPLAIN_RUN:0"; return; fi
  echo "WRITES:1 TARGET_OK:$(detect_target "$dir/graph") NO_MUTUAL:$(detect_mutual "$dir") EXPLAIN_RUN:$(detect_explain "$out")"
}

# Detectors. explain_edges reads edges through the lint's own `--explain` rendering, so the harness
# carries no second copy of the edge grammar (frontmatter shape, quoting, where a target ends):
# whatever the lint can read is an edge here, and whatever it cannot is not. Only the EXPLAIN
# block is parsed (`  SRC rel TARGET "summary"`, one line per edge, up to the blank line that
# closes it); its `(no node X)` notes and the report after it are dropped. The output is captured
# before awk for the pipefail reason detect_mutual gives below.
explain_edges(){ # $1=fixture root (the directory that holds graph/), rest=node IDs -> one "SRC rel TARGET" line per edge
  local out; out=$(bash "$LINT" --explain "$@" 2>/dev/null)
  printf '%s\n' "$out" | awk '/^EXPLAIN \(/ {on=1; next} on && !NF {exit} on && $1 !~ /^\(/ {print $1, $2, $3}'
}
# TARGET_OK: the target gained an invalidated_by edge (one whose target is not among the edges the
# pristine fixture ships with; EXP-002 already cites NODE-003) and the decoy carries none. The new
# edge's target kind is not asserted: the property under test is WHICH node received the edge, and
# a finding recorded as any node kind still had to be linked to the right experiment. The baseline
# is read from a fresh fixture through the same rendering, not kept by hand.
mkfix "$T/base"
BASE_INV=$(explain_edges "$T/base" "$TARGET" | awk '$2=="invalidated_by" {printf "%s ", $3}')
detect_target(){ # $1=graph dir -> 0|1   (the lint wants the directory that holds it, hence dirname)
  explain_edges "$(dirname "$1")" "$TARGET" "$DECOY" | awk -v target="$TARGET" -v decoy="$DECOY" -v base="$BASE_INV" '
    BEGIN {n=split(base, b, " "); for (i=1; i<=n; i++) seen[b[i]]=1}
    $2!="invalidated_by" {next}
    $1==target && !($3 in seen) {gained=1}
    $1==decoy {bad=1}
    END {print (gained && !bad ? 1 : 0)}'
}
# NO_MUTUAL: the lint, read-only, on the fixture root (it wants the directory that holds graph/).
# Its mutual-edge error is the one deterministic reading of "reversed pair"; no second regex here.
# The output is captured before grep because the lint exits non-zero on any error and pipefail
# would turn a found pair into "not found" (self-check 3 caught exactly that).
detect_mutual(){ # $1=fixture root -> 0|1
  local out; out=$(bash "$LINT" "$1" 2>/dev/null)
  printf '%s' "$out" | grep -q ': mutual ' && echo 0 || echo 1
}
# EXPLAIN_RUN: assistant tool_use blocks only, Bash only, command containing --explain, AND the
# tool_result paired to it by id shows the lint rendered edges (`EXPLAIN (`) rather than bailing
# (flag not first prints usage; wrong cwd prints "no graph/ directory"). The skill text arrives in
# a tool_result (a user-role message) and mentions --explain; that is not a run, and neither is a
# --explain command whose result never arrived. A tool_result's content is a string or an array of
# {type: text, text} blocks; both are flattened to text before the check.
detect_explain(){ # $1=stream-json text -> 0|1
  local n
  n=$(printf '%s' "$1" | jq -rs '
        ([.[] | select(.type=="user") | .message.content[]? | select(.type=="tool_result")
          | select(.tool_use_id != null)
          | {key: .tool_use_id, value: (if (.content | type) == "array"
              then ([.content[] | .text? // ""] | join("\n")) else (.content // "") end)}]
         | from_entries) as $result
        | [.[] | select(.type=="assistant") | .message.content[]?
          | select(.type=="tool_use") | select(.name=="Bash")
          | select((.input.command // "") | contains("--explain"))
          | $result[.id // ""] // ""
          | select(contains("EXPLAIN (") and (contains("no graph/ directory") | not))] | length' 2>/dev/null)
  [ "${n:-0}" -gt 0 ] 2>/dev/null && echo 1 || echo 0
}
first_body_line(){ # $1=node file -> first non-blank line after the frontmatter
  awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; body=1; next} body && NF {print; exit}' "$1"
}

# Deterministic self-checks: the harness's own detectors, on graphs and streams with a known answer.
# A wrong detector would otherwise be measured as an agent behavior.
sc_fail=0
sc(){ [ "$2" = "$3" ] && echo "  selfcheck ok: $1" || { echo "  selfcheck FAIL: $1 (got $2, want $3)"; sc_fail=1; }; }
add_edge(){ # $1=node file $2=rel $3=target: one edge line inside the frontmatter, before the closing fence
  awk -v line="  - {rel: $2, to: $3}" 'NR>1 && /^---$/ && !done {print line; done=1} {print}' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
mkobs(){ # $1=graph dir [$2=target of a reverse invalidated_by edge] -> writes OBS-002
  { printf -- '---\nid: OBS-002\nkind: observation\n'
    [ -n "${2:-}" ] && printf 'edges:\n  - {rel: invalidated_by, to: %s}\n' "$2"
    printf -- '---\nThe BM25 corpus held the eval gold passages; the original hybrid lead was inflated.\n'
  } > "$1/OBS-002.md"
}
mkfix "$T/sc1"; mkobs "$T/sc1/graph"; add_edge "$T/sc1/graph/$TARGET.md" invalidated_by OBS-002
sc "edge on the intended experiment -> TARGET_OK 1" "$(detect_target "$T/sc1/graph")" 1
mkfix "$T/sc2"; mkobs "$T/sc2/graph"; add_edge "$T/sc2/graph/$DECOY.md" invalidated_by OBS-002
sc "edge on the decoy instead -> TARGET_OK 0" "$(detect_target "$T/sc2/graph")" 0
sc "pristine fixture, nothing gained -> TARGET_OK 0" "$(detect_target "$T/base/graph")" 0
mkfix "$T/sc4"; mkobs "$T/sc4/graph"; add_edge "$T/sc4/graph/$TARGET.md" invalidated_by OBS-002; add_edge "$T/sc4/graph/$DECOY.md" invalidated_by OBS-002
sc "edges on both the target and the decoy -> TARGET_OK 0" "$(detect_target "$T/sc4/graph")" 0
mkfix "$T/sc3"; mkobs "$T/sc3/graph" "$TARGET"; add_edge "$T/sc3/graph/$TARGET.md" invalidated_by OBS-002
sc "reversed pair -> NO_MUTUAL 0, one-way edge -> 1" "$(detect_mutual "$T/sc3")$(detect_mutual "$T/sc1")" 01
sc "assistant Bash --explain tool_use paired with an EXPLAIN result -> EXPLAIN_RUN 1" "$(detect_explain "$(printf '%s\n' \
  '{"type":"system","subtype":"init"}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"bash /p/plugin/scripts/graph-lint.sh --explain . EXP-002 OBS-002","description":"review the new edges"}}]}}' \
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"EXPLAIN (3 edges):\n  EXP-002 part_of THEORY-001 \"Hybrid keyword+vector retrieval beats vector-only on our eval set.\"\n  EXP-002 invalidated_by OBS-002 \"The BM25 corpus held the eval gold passages; the original hybrid lead was inflated.\"\n  OBS-002 part_of THEORY-001 \"Hybrid keyword+vector retrieval beats vector-only on our eval set.\"\n\ngraph-lint: 13 node(s) in ./graph\nclean: no integrity problems found.\n\n0 error(s), 0 warning(s)."}]}]}}' \
  '{"type":"result","subtype":"success","result":"done"}')")" 1
sc "--explain paired with a no-graph result -> EXPLAIN_RUN 0" "$(detect_explain "$(printf '%s\n' \
  '{"type":"system","subtype":"init"}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"bash /p/plugin/scripts/graph-lint.sh --explain . EXP-002 OBS-002","description":"review the new edges"}}]}}' \
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"graph-lint: no graph/ directory here; repo is not scaffolded for tendrel. Nothing to lint."}]}}' \
  '{"type":"result","subtype":"success","result":"done"}')")" 0
sc "--explain not first (usage error), an EXPLAIN block under another id -> EXPLAIN_RUN 0" "$(detect_explain "$(printf '%s\n' \
  '{"type":"system","subtype":"init"}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"bash /p/plugin/scripts/graph-lint.sh . --explain EXP-002 OBS-002","description":"review the new edges"}}]}}' \
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"usage: graph-lint.sh [--explain] [repo-dir] [NODE-ID ...]   (--explain must be the first argument)"}]}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/p/plugin/skills/research-graph/SKILL.md"}}]}}' \
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"EXPLAIN (3 edges):\n  EXP-002 invalidated_by OBS-002 \"The BM25 corpus held the eval gold passages; the original hybrid lead was inflated.\""}]}]}}' \
  '{"type":"result","subtype":"success","result":"done"}')")" 0
sc "--explain tool_use with no paired tool_result at all -> EXPLAIN_RUN 0" "$(detect_explain "$(printf '%s\n' \
  '{"type":"system","subtype":"init"}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"bash /p/plugin/scripts/graph-lint.sh --explain . EXP-002 OBS-002","description":"review the new edges"}}]}}' \
  '{"type":"result","subtype":"success","result":"done"}')")" 0
sc "--explain only in a tool_result and chat text -> EXPLAIN_RUN 0" "$(detect_explain "$(printf '%s\n' \
  '{"type":"system","subtype":"init"}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/p/plugin/skills/research-graph/SKILL.md"}}]}}' \
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"run graph-lint.sh --explain . <touched node IDs> and review each rendered line"}]}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I could run --explain here but will lint instead."},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"bash /p/plugin/scripts/graph-lint.sh .","description":"lint"}}]}}' \
  '{"type":"result","subtype":"success","result":"done"}')")" 0
mkfix "$T/sc6"
tl=$(first_body_line "$T/sc6/graph/$TARGET.md"); dl=$(first_body_line "$T/sc6/graph/$DECOY.md")
sc "decoy's first body line differs from the target's" "$([ -n "$tl" ] && [ -n "$dl" ] && [ "$tl" != "$dl" ] && echo 1 || echo 0)" 1
[ "$sc_fail" -eq 0 ] || { echo "detector self-checks failed; the measurement would be meaningless."; exit 1; }
[ "$SELFCHECK_ONLY" -eq 0 ] || { echo "self-checks passed; --selfcheck-only set, no model call made."; exit 0; }

w=0; t=0; m=0; x=0; e=0
echo "== edge-review contract: finding narrated by meaning, decoy shares the vocabulary, N=$N =="
for i in $(seq 1 "$N"); do
  d="$T/run_$i"; mkfix "$d"
  r=$(run_once "$d"); echo "  run $i: $r"
  echo "$r" | grep -q "RUN:ERR"       && e=$((e+1))
  echo "$r" | grep -q "WRITES:1"      && w=$((w+1))
  echo "$r" | grep -q "TARGET_OK:1"   && t=$((t+1))
  echo "$r" | grep -q "NO_MUTUAL:1"   && m=$((m+1))
  echo "$r" | grep -q "EXPLAIN_RUN:1" && x=$((x+1))
done
echo "  ==> wrote the graph in $w/$N runs; invalidated_by on $TARGET and not on $DECOY in $t/$w writes; no reversed pair in $m/$w writes; ran --explain in $x/$w writes ($e errored)"

fail=0
if [ "$e" -gt 0 ]; then echo "  FAIL: $e/$N runs errored; the measurement is incomplete and certifies nothing."; fail=1; fi
if [ "$e" -eq 0 ] && [ "$w" -eq 0 ]; then echo "  FAIL: no run wrote the graph; the contract was never observable."; fail=1; fi
if [ "$w" -gt 0 ] && [ "$t" -eq 0 ]; then echo "  FAIL: the graph was written but no run put the invalidated_by edge on $TARGET and off $DECOY; targets were guessed, not read."; fail=1; fi
if [ "$w" -gt 0 ] && [ "$x" -eq 0 ]; then echo "  NOTE: no write ran --explain; check that the review sentence reached the model before rewording it."; fi
if [ "$w" -gt 0 ] && [ "$m" -lt "$w" ]; then echo "  NOTE: $((w-m))/$w writes left a reversed invalidated_by pair; the lint catches it, the review should have."; fi
echo "Targets: invalidated_by on $TARGET in >0 writes (hard); --explain run and no reversed pair are rates, reported not asserted."
[ "$fail" -eq 0 ]
