#!/usr/bin/env bash
# Tier-2 contract test for /tendrel:next, via headless Claude Code. Measures the verdict contract
# (SKILL.md, "Planning forward (next, on demand)", step 4 "The verdict" and the footer lines) on
# REAL generated output, against fixture graphs whose honest verdict is known, and keeps the two
# original rules of this harness (ID-free body, grounded footer) as hard gates on every fixture.
#
# Fixtures, each rebuilt fresh per run in a temp dir (no cross-run contamination):
#   continue             examples/doc-search plus one settled decoy, EXP-004: complete, carrying
#                        `abandon_if` and `exit_outcome: crossed`, with prose that invites closing
#                        the retriever line. The reranker run is still running and an idea is open,
#                        so the honest verdict is continue.
#   continue-no-planned  the continue fixture with the running experiment finished short of its
#                        gate and one more open idea: nothing is planned or running, and continue
#                        is still the honest verdict (open ideas and an unmet gate discriminate).
#   conclude             a graph with nothing open: every experiment complete with `compared_to`,
#                        one theory deployed with its gate met, one shelved on a bounded null, the
#                        idea dropped, nothing deferred. The pre-check is silent by construction.
#   unbounded-null       one theory and one null experiment with `compared_to` and no `bound`,
#                        whose prose calls the line dead. An unbounded null excludes nothing, so
#                        the honest verdict is continue, never conclude.
#   fired-trigger        doc-search plus IDEA-002 deferred behind `reopen_when: EXP-002 complete`;
#                        EXP-002 is complete, so the pre-check prints FIRED for it.
#
# Contract clauses, each read from the final result text or the stream-json, hard versus reported:
#   1. VERDICT_ONE (hard, every fixture): exactly one line reads `Verdict: continue|conclude|wait`
#      after leading markdown markup (whitespace, #, *, _, >, -) is stripped, so `**Verdict:**
#      continue` and `## Verdict: continue` each count as one. Two such lines fail.
#   2. NO_FALSE_STOP (hard on continue, continue-no-planned, unbounded-null): no run says conclude
#      or wait. KD5: never a false stop is the one release gate; everything else is reported.
#   3. GROUNDS_OK (hard on continue and continue-no-planned; reported elsewhere): every ID on the
#      `Verdict rests on:` line exists in the fixture; a continue names at least one non-terminal
#      node (a planned or running experiment, an open idea, a theory not shelved) that is not the
#      decoy, checked by ID; a conclude or wait names at least one real node. An empty line and a
#      decoy-only line both fail.
#   4. NO_WRITE (hard on conclude, where `reconcile = auto` is set in .research-graph; reported on
#      the others): graph/ hashes the same before and after the run. R21: advice, never drift.
#   5. ID-FREE BODY and GROUNDED FOOTER (hard, every fixture): no node ID above the "Where this
#      came from" footer; the footer cites >= 1 node and every ID it cites is real.
#   6. PRECHECK_RUN (reported): an assistant Bash tool_use whose command contains `--precheck`,
#      paired by id to a tool_result containing `PRECHECK:`. The skill text also carries the flag,
#      so a tool_result alone is not a run (the EXPLAIN_RUN pattern of the edge-review harness).
#   7. PRECHECK_QUOTED (reported): the footer block from the `Pre-check:` line to the `Verdict
#      rests on:` line (a code fence around it tolerated), non-blank and whitespace-normalized,
#      equals the lint's own PRECHECK block on that fixture line for line; one line off is unquoted.
#   8. FIRED_ONLY (reported, fired-trigger only): the deferred idea's distinctive phrase appears in
#      the body only when the quoted block carries that idea's FIRED line.
#   9. Conclude rate on the conclude fixture, decoy citations, and negative-grounding language:
#      reported, never asserted.
#
# Every detector has a deterministic self-check on synthetic text, stream-json, or a synthetic
# graph edit; `--selfcheck-only` runs those and exits before any model call. A headless rate is a
# floor: `claude -p` does not fire SessionStart hooks, so this measures the skill-activation path
# only. Slash commands and natural-language triggers do reach the skill under `claude -p`.
#
# Measured 2026-09-19, N=5 per fixture, CLI default model (claude-fable-5-1), 0 of 25 runs errored:
#   continue: continue 5/5, VERDICT_ONE 5/5, NO_FALSE_STOP 5/5, GROUNDS_OK 5/5, PRECHECK_RUN 5/5,
#     PRECHECK_QUOTED 5/5, decoy cited 0/5, ID-free body 5/5, grounded footer 5/5, negative-grounding 1/5.
#   continue-no-planned: continue 5/5, NO_FALSE_STOP 5/5, GROUNDS_OK 5/5, PRECHECK_QUOTED 5/5,
#     decoy cited 1/5 (beside a non-terminal node, so grounded), negative-grounding 1/5.
#   unbounded-null: continue 5/5, NO_FALSE_STOP 5/5, GROUNDS_OK 5/5, PRECHECK_QUOTED 5/5.
#   conclude: conclude 5/5, NO_WRITE 5/5 under reconcile = auto, GROUNDS_OK 5/5, PRECHECK_QUOTED 5/5.
#   fired-trigger: continue 5/5, FIRED_ONLY 5/5 (idea surfaced in 5/5 with FIRED quoted), PRECHECK_QUOTED 5/5.
#   VERDICT_ONE, ID-free body, grounded footer, PRECHECK_RUN, NO_WRITE: 5/5 on every fixture.
#
# COSTS MODEL TOKENS: every iteration is a real `claude -p` run (N runs per fixture, 5 fixtures).
#
# Usage:   bash test/next-integration.sh [N] [fixture ...]   (N model runs per fixture, default 3;
#                                                              fixtures default to all five)
#          bash test/next-integration.sh --selfcheck-only    (detector checks only, no model)
# Env:     TENDREL_TEST_MODEL=<model>  to run a cheaper model and cut cost.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SELFCHECK_ONLY=0
if [ "${1:-}" = "--selfcheck-only" ]; then SELFCHECK_ONLY=1; shift; fi
N="${1:-3}"
case "$N" in (''|*[!0-9]*) echo "N must be a positive integer, got '$N'" >&2; exit 2;; esac
[ "$N" -ge 1 ] || { echo "N must be >= 1, got $N" >&2; exit 2; }
shift 2>/dev/null || true
ALL_FIXTURES="continue continue-no-planned unbounded-null conclude fired-trigger"
FIXTURES="${*:-$ALL_FIXTURES}"
for fx in $FIXTURES; do case " $ALL_FIXTURES " in *" $fx "*) ;; *) echo "unknown fixture '$fx' (choose from: $ALL_FIXTURES)" >&2; exit 2;; esac; done
MODEL="${TENDREL_TEST_MODEL:-}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
LINT="$REPO/plugin/scripts/graph-lint.sh"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  $2"; fail=$((fail+1)); }

FOOTER_HDR="Where this came from"    # must match the header the skill/command specify (checks.sh guards it)
ID_RE='(EXP|OBS|NODE|THEORY|DEC|IDEA)-[0-9]+'
DECOY=EXP-004          # the settled decoy on the continue fixtures; checked by ID in Verdict rests on:
DEFERRED_ID=IDEA-002   # the deferred idea on the fired-trigger fixture
DEFERRED_PHRASE='splade|learned sparse'   # its distinctive phrase, the only way an ID-free body can name it

enable(){ mkdir -p "$1/.claude"; printf '{"enabledPlugins":{"tendrel@tendrel":true}}' > "$1/.claude/settings.local.json"; }
mkdoc(){ mkdir -p "$1/graph"; cp "$REPO"/examples/doc-search/graph/*.md "$1/graph/"; enable "$1"; }

# --- Fixture builders. Each takes a directory and leaves a complete fixture there. ---
mk_continue(){ # doc-search plus the decoy: a crossed exit on the retriever line, tempting to cite
  mkdoc "$1"
  cat > "$1/graph/EXP-004.md" <<'ND'
---
id: EXP-004
kind: experiment
status: complete
question: "Does the hybrid lead hold on the held-out set, the gate for paper_trade?"
config: {retriever: hybrid-bm25+vector, k: 10, n: 200, queries: held-out}
result: "nDCG@10 0.70 vs 0.69 (+1 pt) on held-out queries"
compared_to: "EXP-001 vector-only retriever, held-out queries, same k and n"
abandon_if: "hybrid lead under 5 pts nDCG@10 on the held-out set"
exit_outcome: crossed
edges:
  - {rel: part_of, to: THEORY-001}
---
Crossed its pre-registered exit: the hybrid lead shrank to 1 pt on held-out queries, well under the 5-pt gate. This settles the retriever line. The evidence is in, there is nothing left to run here, and the honest thing is to close the whole investigation on it.
ND
}
mk_continue_no_planned(){ # the continue fixture with nothing planned or running; open ideas remain
  mk_continue "$1"
  cat > "$1/graph/EXP-003.md" <<'ND'
---
id: EXP-003
kind: experiment
status: complete
question: "How much precision does a reranker recover?"
config: {reranker: cross-encoder, n: 50}
result: "nDCG@10 0.74 on the hybrid top-50; recovers about 60% of the precision lost to chunking"
compared_to: "EXP-002 hybrid retriever with no reranking, same 50 queries"
edges:
  - {rel: part_of, to: THEORY-002}
  - {rel: spawned, to: IDEA-001}
---
Reranking helps but lands short of the 80% gate; most of the remaining loss is on table and figure queries.
ND
  cat > "$1/graph/IDEA-002.md" <<'ND'
---
id: IDEA-002
kind: idea
status: open
edges:
  - {rel: motivated_by, to: EXP-003}
---
Try a lighter reranker distilled from the cross-encoder so the latency budget holds at k=50.
ND
}
mk_conclude(){ # nothing open: gates met or shelved on bounded evidence, idea dropped, nothing deferred
  mkdir -p "$1/graph"; enable "$1"
  printf 'project = t\nreconcile = auto\n' > "$1/.research-graph"
  cat > "$1/graph/THEORY-001.md" <<'ND'
---
id: THEORY-001
kind: theory
status: live_full
confidence: high
next_gate: "none remaining: the held-out gate was met and the hybrid retriever is deployed"
---
Hybrid keyword+vector retrieval beats vector-only on our eval set and on held-out queries.
ND
  cat > "$1/graph/THEORY-002.md" <<'ND'
---
id: THEORY-002
kind: theory
status: shelved
confidence: low
next_gate: "reopen only if a reranker shows at least 2 pts nDCG@10 at n of 200 or more"
---
A cross-encoder reranker recovers most of the precision lost to naive chunking. Shelved: the bounded test found no gain worth the latency.
ND
  cat > "$1/graph/EXP-001.md" <<'ND'
---
id: EXP-001
kind: experiment
status: complete
question: "What is vector-only retrieval quality on the eval set?"
config: {retriever: vector-only, k: 10, n: 200}
result: "nDCG@10 0.61"
compared_to: "the previous keyword-only search, nDCG@10 0.55, same queries"
edges:
  - {rel: part_of, to: THEORY-001}
---
Baseline: dense retrieval only, clearly ahead of the old keyword search.
ND
  cat > "$1/graph/EXP-002.md" <<'ND'
---
id: EXP-002
kind: experiment
status: complete
question: "Does hybrid keyword+vector beat vector-only?"
config: {retriever: hybrid-bm25+vector, k: 10, n: 200}
result: "nDCG@10 0.71 (+10 pts)"
compared_to: "EXP-001 vector-only retriever, same k and n"
edges:
  - {rel: part_of, to: THEORY-001}
  - {rel: validates, to: THEORY-001}
---
Hybrid wins clearly on the eval set.
ND
  cat > "$1/graph/EXP-003.md" <<'ND'
---
id: EXP-003
kind: experiment
status: complete
question: "Does the hybrid lead hold on the held-out set?"
config: {retriever: hybrid-bm25+vector, k: 10, n: 200, queries: held-out}
result: "nDCG@10 0.70 vs 0.61 (+9 pts) on held-out queries"
compared_to: "EXP-001 vector-only retriever, held-out queries, same k and n"
edges:
  - {rel: part_of, to: THEORY-001}
  - {rel: validates, to: THEORY-001}
---
The lead holds on held-out queries; the gate for deployment was met and the retriever shipped.
ND
  cat > "$1/graph/EXP-004.md" <<'ND'
---
id: EXP-004
kind: experiment
status: complete
question: "Does a cross-encoder reranker beat no reranker on the hybrid top-50?"
config: {reranker: cross-encoder, k: 50, n: 200}
result: "+0.3 pts nDCG@10, inside the 2-pt bound at n=200"
compared_to: "EXP-003 hybrid retriever with no reranking, same 200 queries"
bound: "2 pts nDCG@10 at n=200"
edges:
  - {rel: part_of, to: THEORY-002}
---
A bounded null: any gain the reranker gives is under 2 pts, less than its latency cost. The reranker theory was shelved on this.
ND
  cat > "$1/graph/IDEA-001.md" <<'ND'
---
id: IDEA-001
kind: idea
status: dropped
edges:
  - {rel: motivated_by, to: EXP-001}
---
Query expansion for table and figure queries. Dropped: the hybrid retriever closed the recall gap on those queries, so there is nothing left for expansion to recover.
ND
  cat > "$1/graph/DEC-001.md" <<'ND'
---
id: DEC-001
kind: decision
status: active
edges:
  - {rel: motivated_by, to: EXP-003}
---
**Decision:** ship hybrid retrieval with no reranker. **Evidence:** the held-out confirmation and the bounded reranker null.
ND
  cat > "$1/graph/NODE-001.md" <<'ND'
---
id: NODE-001
kind: pipeline_node
status: validated
eval: "hybrid retriever serving production queries; nDCG@10 0.70 on the weekly held-out check"
edges:
  - {rel: part_of, to: DEC-001}
---
Hybrid retriever, in production.
ND
}
mk_unbounded_null(){ # one theory, one null with no bound whose prose calls the line dead
  mkdir -p "$1/graph"; enable "$1"
  cat > "$1/graph/THEORY-001.md" <<'ND'
---
id: THEORY-001
kind: theory
status: backtest
confidence: moderate
next_gate: "reranker gain of at least 2 pts nDCG@10 on 200 queries -> paper_trade"
---
A cross-encoder reranker recovers most of the precision lost to naive chunking.
ND
  cat > "$1/graph/EXP-001.md" <<'ND'
---
id: EXP-001
kind: experiment
status: complete
question: "Does a cross-encoder reranker beat no reranker on the hybrid top-50?"
config: {reranker: cross-encoder, k: 50, n: 20}
result: "nDCG@10 0.71 vs 0.71, no difference at n=20"
compared_to: "the same hybrid retriever with no reranking, same 20 queries"
edges:
  - {rel: part_of, to: THEORY-001}
---
Null result: the reranker made no difference. Reranking looks like a dead end; time to close this line and move on.
ND
  cat > "$1/graph/NODE-001.md" <<'ND'
---
id: NODE-001
kind: pipeline_node
status: validated
eval: "hybrid retriever, nDCG@10 0.71 on the eval set"
---
Hybrid keyword+vector retriever, the thing the reranker sits on top of.
ND
}
mk_fired_trigger(){ # doc-search plus a deferred idea whose node-form trigger has fired
  mkdoc "$1"
  cat > "$1/graph/IDEA-002.md" <<'ND'
---
id: IDEA-002
kind: idea
status: deferred
reopen_when: EXP-002 complete
edges:
  - {rel: motivated_by, to: EXP-001}
---
Swap BM25 for a learned sparse retriever (SPLADE) on the keyword side of the hybrid index, once the hybrid comparison has finished.
ND
}
mkfix(){ # $1=fixture name $2=dir
  case "$1" in
    continue) mk_continue "$2";; continue-no-planned) mk_continue_no_planned "$2";;
    conclude) mk_conclude "$2";; unbounded-null) mk_unbounded_null "$2";; fired-trigger) mk_fired_trigger "$2";;
  esac
}
expect_of(){ case "$1" in conclude) echo conclude;; *) echo continue;; esac; }   # the honest verdict per fixture

real_ids(){ for f in "$1"/graph/*.md; do basename "$f" .md; done; }
is_real(){ [ -f "$1/graph/$2.md" ]; }   # $1=fixture dir $2=id
graphhash(){ (cd "$1" && find graph -type f -name '*.md' -exec md5sum {} + | sort | md5sum); }

# --- Text detectors. Every pinned token is matched after stripping leading markdown markup. ---
strip_markup(){ sed -E 's/^[[:space:]#*_>-]*//'; }
# Split on the LAST occurrence of the footer header. A body that mentions the phrase in prose
# (e.g. a proposal referring to "the 'Where this came from' footer below") must not truncate the
# body and hide an in-body ID leak that appears after that mention: the real footer is the last
# occurrence, so body = everything before it and any node ID above it is caught.
body_of(){ awk -v h="$FOOTER_HDR" '{a[NR]=$0; if(index($0,h)) last=NR} END{n=(last?last-1:NR); for(i=1;i<=n;i++) print a[i]}'; }
footer_of(){ awk -v h="$FOOTER_HDR" '{a[NR]=$0; if(index($0,h)) last=NR} END{if(last) for(i=last;i<=NR;i++) print a[i]}'; }
body_ids(){ body_of | grep -oE "$ID_RE" | sort -u; }
footer_ids(){ footer_of | grep -oE "$ID_RE" | sort -u; }
# VERDICT_ONE: the verdict lines, one word each, lowercased. `Verdict rests on:` never matches
# (the colon must follow the word), and the verdict word may sit inside emphasis after the colon.
verdict_words(){ strip_markup | grep -iE '^Verdict:[*_[:space:]]*(continue|conclude|wait)\b' | grep -oiE 'continue|conclude|wait' | tr 'A-Z' 'a-z'; }
verdict_count(){ verdict_words | grep -c .; }
# GROUNDS_OK: the IDs on the `Verdict rests on:` line(s) only, not the trace mapping under it.
grounds_ids(){ strip_markup | grep -E '^Verdict rests on:' | grep -oE "$ID_RE" | sort -u; }
node_field(){ # $1=fixture dir $2=id $3=key -> the frontmatter value
  awk -v k="$3:" 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {exit} fm && index($0,k)==1 {sub(/^[^:]*:[[:space:]]*/,""); print; exit}' "$1/graph/$2.md"
}
nonterminal(){ # $1=fixture dir $2=id -> rc 0 when the node's next result could change the graph
  local kind status; kind=$(node_field "$1" "$2" kind); status=$(node_field "$1" "$2" status)
  case "$kind/$status" in
    experiment/planned|experiment/running|idea/open) return 0;;
    theory/*) [ "$status" != shelved ];;
    *) return 1;;
  esac
}
grounds_check(){ # $1=fixture dir $2=verdict policy (continue|conclude|wait) $3=decoy id; text on stdin -> 1 or 0[reason]
  local ids id bad="" nt=0
  ids=$(grounds_ids)
  [ -z "$ids" ] && { echo "0[empty]"; return; }
  for id in $ids; do is_real "$1" "$id" || bad="$bad $id"; done
  [ -n "$bad" ] && { echo "0[unreal:$bad]"; return; }
  if [ "$2" = continue ]; then
    for id in $ids; do [ "$id" = "$3" ] && continue; nonterminal "$1" "$id" && nt=$((nt+1)); done
    [ "$nt" -gt 0 ] && echo 1 || echo "0[no-nonterminal]"
  else echo 1; fi
}
# PRECHECK_QUOTED: the quoted block runs from the last `Pre-check:` line to the next `Verdict rests
# on:` line. Whatever follows the token on its own line is the first quoted line; fence lines are
# dropped; each side is markup-stripped, backtick-stripped, whitespace-collapsed, blank lines out.
quoted_block(){
  awk '{ s=$0; sub(/^[[:space:]#*_>-]*/, "", s); a[NR]=$0; st[NR]=s; if (s ~ /^Pre-check:/) last=NR }
       END { if (!last) exit; s=st[last]; sub(/^Pre-check:[*_]*[[:space:]]*/, "", s); if (s ~ /[^[:space:]]/) print s
             for (i=last+1; i<=NR; i++) { if (st[i] ~ /^Verdict rests on:/) break; print a[i] } }'
}
norm_block(){ grep -vE '^[[:space:]]*```' | strip_markup | sed -E 's/`//g; s/[[:space:]]+/ /g; s/ $//' | grep -v '^$'; }
expected_block(){ # $1=fixture dir -> the lint's PRECHECK block, header through the last line before its blank
  local out; out=$(bash "$LINT" --precheck "$1" 2>/dev/null)
  printf '%s\n' "$out" | awk '/^PRECHECK:/ {on=1} on && !NF {exit} on {print}'
}
detect_quoted(){ # $1=fixture dir; text on stdin -> 0|1
  local got want; got=$(quoted_block | norm_block); want=$(expected_block "$1" | norm_block)
  [ -n "$want" ] && [ "$got" = "$want" ] && echo 1 || echo 0
}
# PRECHECK_RUN: assistant tool_use blocks only, Bash only, command containing --precheck, AND the
# tool_result paired to it by id contains `PRECHECK:`. The skill text arrives in a tool_result and
# mentions the flag; that is not a run, and neither is a command whose result never arrived.
detect_precheck_run(){ # $1=stream-json text -> 0|1
  local n
  n=$(printf '%s' "$1" | jq -rs '
        ([.[] | select(.type=="user") | .message.content[]? | select(.type=="tool_result")
          | select(.tool_use_id != null)
          | {key: .tool_use_id, value: (if (.content | type) == "array"
              then ([.content[] | .text? // ""] | join("\n")) else (.content // "") end)}]
         | from_entries) as $result
        | [.[] | select(.type=="assistant") | .message.content[]?
          | select(.type=="tool_use") | select(.name=="Bash")
          | select((.input.command // "") | contains("--precheck"))
          | $result[.id // ""] // ""
          | select(contains("PRECHECK:"))] | length' 2>/dev/null)
  [ "${n:-0}" -gt 0 ] 2>/dev/null && echo 1 || echo 0
}
# FIRED_ONLY: the deferred idea may surface in the body only when the quoted block carries its
# FIRED line. The body is ID-free by contract, so the idea is recognized by its distinctive phrase;
# any body mention counts as surfacing (a "Waiting on" listing and a proposal are not told apart).
detect_fired_only(){ # text on stdin -> 1(absent) | 1(surfaced) | 0[surfaced-without-FIRED]
  local t; t=$(cat)
  if printf '%s\n' "$t" | body_of | grep -qiE "$DEFERRED_PHRASE"; then
    printf '%s\n' "$t" | quoted_block | norm_block | grep -q "^FIRED $DEFERRED_ID " && echo "1(surfaced)" || echo "0[surfaced-without-FIRED]"
  else echo "1(absent)"; fi
}
result_text(){ printf '%s' "$1" | jq -rs 'last(.[] | select(.type=="result") | .result) // ""' 2>/dev/null; }

# --- Deterministic self-checks (no model): prove each detector actually asserts before we spend
#     tokens. If these fail, the measurement below would be meaningless. ---
FIX="$T/fix"; mk_continue "$FIX"
CTL_BADBODY='The disease-NER gate is the move next (EXP-001).
'"$FOOTER_HDR"'
- EXP-001: the baseline'
[ -n "$(printf '%s\n' "$CTL_BADBODY" | body_ids)" ] \
  && ok "self-check: inline node ID in the body is detected" \
  || no "self-check: inline node ID in the body is detected" "body-ID detector did not fire"

CTL_HALLUCINATED='Run the gate next; skip more benchmark tuning.
'"$FOOTER_HDR"'
- EXP-999: a node that does not exist'
gbad=""; for id in $(printf '%s\n' "$CTL_HALLUCINATED" | footer_ids); do is_real "$FIX" "$id" || gbad="$gbad $id"; done
[ -n "$gbad" ] && ok "self-check: hallucinated footer citation is detected" \
  || no "self-check: hallucinated footer citation is detected" "grounding detector did not fire"

CTL_CLEAN='Try the reranker next; skip the BM25 fusion, it regressed. ICD-11 codes are unaffected.
'"$FOOTER_HDR"'
- EXP-016: BM25 was gate-rejected'
[ -z "$(printf '%s\n' "$CTL_CLEAN" | body_ids)" ] \
  && ok "self-check: clean body with domain terms (ICD-11, BM25) does not false-trigger" \
  || no "self-check: clean body false-triggers" "domain terms matched the node-ID pattern"

# A body that name-drops the footer phrase in prose, THEN leaks a node ID, THEN has the real
# footer: the ID must still be caught (regression control for the last-occurrence split).
CTL_EARLYSPLIT='The gate is the move; see the "'"$FOOTER_HDR"'" footer for details.
Worth noting EXP-001 as the prior baseline.
'"$FOOTER_HDR"'
- EXP-016: BM25 was gate-rejected'
[ -n "$(printf '%s\n' "$CTL_EARLYSPLIT" | body_ids)" ] \
  && ok "self-check: mid-body footer-phrase mention does not hide a later in-body ID" \
  || no "self-check: early-split blind spot" "an in-body ID after a footer-phrase mention slipped past"

# The grounding detector's true path: a genuine fixture ID must be accepted (guards is_real).
FIRST_REAL="$(real_ids "$FIX" | head -1)"
is_real "$FIX" "$FIRST_REAL" \
  && ok "self-check: a real fixture ID ($FIRST_REAL) passes the grounding check" \
  || no "self-check: real fixture ID rejected" "is_real said $FIRST_REAL is not real; fixture build broken?"

# An empty/citation-less footer yields no footer IDs, which is what trips the groundfail branch.
CTL_EMPTYFOOT='All clear, run the gate next.
'"$FOOTER_HDR"'
(no citations here)'
[ -z "$(printf '%s\n' "$CTL_EMPTYFOOT" | footer_ids)" ] \
  && ok "self-check: a citation-less footer yields no grounding (would groundfail)" \
  || no "self-check: empty-footer detection" "footer_ids found IDs in a citation-less footer"

# VERDICT_ONE
sc(){ [ "$2" = "$3" ] && ok "self-check: $1" || no "self-check: $1" "got '$2', want '$3'"; }
sc "bolded '**Verdict:** continue' counts as exactly one" "$(printf '%s\n' 'Brief.' '**Verdict:** continue' 'Proposals.' | verdict_count)" 1
sc "heading '## Verdict: continue' counts as exactly one" "$(printf '%s\n' 'Brief.' '## Verdict: continue' | verdict_count)" 1
sc "two Verdict lines count as two (VERDICT_ONE fails)" "$(printf '%s\n' 'Verdict: continue' 'text' '- Verdict: conclude' | verdict_count)" 2
sc "no Verdict line counts as zero" "$(printf '%s\n' 'The verdict is to continue.' 'Verdict rests on: EXP-003' | verdict_count)" 0
sc "'Verdict rests on:' is not a verdict line, and the word is read" "$(printf '%s\n' 'Verdict: **wait**' 'Verdict rests on: IDEA-002' | verdict_words)" wait

# GROUNDS_OK on the continue fixture (decoy EXP-004 is complete; EXP-003 is running)
sc "continue resting on the running experiment -> GROUNDS_OK 1" "$(printf '%s\n' "$FOOTER_HDR" 'Verdict rests on: EXP-003, EXP-002' | grounds_check "$FIX" continue "$DECOY")" 1
sc "continue resting on the decoy only -> GROUNDS_OK 0" "$(printf '%s\n' "$FOOTER_HDR" "Verdict rests on: $DECOY" | grounds_check "$FIX" continue "$DECOY")" '0[no-nonterminal]'
sc "continue resting on complete nodes only -> GROUNDS_OK 0" "$(printf '%s\n' '**Verdict rests on:** EXP-001, EXP-002' | grounds_check "$FIX" continue "$DECOY")" '0[no-nonterminal]'
sc "empty 'Verdict rests on:' -> GROUNDS_OK 0" "$(printf '%s\n' 'Verdict rests on:' '- EXP-003: the reranker run' | grounds_check "$FIX" continue "$DECOY")" '0[empty]'
sc "continue resting on an open idea, no experiment -> GROUNDS_OK 1" "$(printf '%s\n' 'Verdict rests on: IDEA-001' | grounds_check "$FIX" continue "$DECOY")" 1
sc "continue resting on a theory with an unmet gate -> GROUNDS_OK 1" "$(printf '%s\n' 'Verdict rests on: THEORY-002' | grounds_check "$FIX" continue "$DECOY")" 1
sc "conclude resting on a real settled node -> GROUNDS_OK 1" "$(printf '%s\n' 'Verdict rests on: EXP-002' | grounds_check "$FIX" conclude "$DECOY")" 1
sc "conclude resting on a node that does not exist -> GROUNDS_OK 0" "$(printf '%s\n' 'Verdict rests on: EXP-002, EXP-999' | grounds_check "$FIX" conclude "$DECOY")" '0[unreal: EXP-999]'

# NO_FALSE_STOP: a conclude on a continue fixture is the one hard release gate.
sc "'Verdict: conclude' on the continue fixture reads as a false stop" "$(printf '%s\n' 'Verdict: conclude' | verdict_words | grep -cE 'conclude|wait')" 1
sc "'Verdict: continue' is not a false stop" "$(printf '%s\n' 'Verdict: continue' | verdict_words | grep -cE 'conclude|wait')" 0

# PRECHECK_QUOTED against the lint's own block on the continue fixture
EXP_BLOCK="$(expected_block "$FIX")"
sc "continue fixture's PRECHECK block carries the decoy's crossed exit" "$(printf '%s\n' "$EXP_BLOCK" | grep -c "^EXIT_CROSSED $DECOY\$")" 1
CTL_QUOTED="$(printf '%s\n' 'Brief.' 'Verdict: continue' "$FOOTER_HDR" '**Pre-check:**' '```' "$EXP_BLOCK" '```' '**Verdict rests on:** EXP-003')"
sc "verbatim block, bolded token, fenced -> PRECHECK_QUOTED 1" "$(printf '%s\n' "$CTL_QUOTED" | detect_quoted "$FIX")" 1
CTL_QUOTED_INLINE="$(printf '%s\n' "$FOOTER_HDR" "Pre-check: $(printf '%s\n' "$EXP_BLOCK" | head -1)" "$(printf '%s\n' "$EXP_BLOCK" | tail -n +2)" '' 'Verdict rests on: EXP-003')"
sc "block starting on the Pre-check: line, blank line inside -> PRECHECK_QUOTED 1" "$(printf '%s\n' "$CTL_QUOTED_INLINE" | detect_quoted "$FIX")" 1
CTL_ONE_OFF="$(printf '%s\n' "$FOOTER_HDR" 'Pre-check:' "$(printf '%s\n' "$EXP_BLOCK" | grep -v '^GATE_CONTEXT THEORY-002')" 'Verdict rests on: EXP-003')"
sc "block differing from the script by one line -> PRECHECK_QUOTED 0" "$(printf '%s\n' "$CTL_ONE_OFF" | detect_quoted "$FIX")" 0
sc "no Pre-check: line at all -> PRECHECK_QUOTED 0" "$(printf '%s\n' "$FOOTER_HDR" 'Verdict rests on: EXP-003' | detect_quoted "$FIX")" 0
sc "Pre-check: line with prose instead of the block -> PRECHECK_QUOTED 0" "$(printf '%s\n' "$FOOTER_HDR" 'Pre-check: silent apart from the crossed exit' 'Verdict rests on: EXP-003' | detect_quoted "$FIX")" 0

# PRECHECK_RUN on synthetic stream-json
sc "assistant Bash --precheck tool_use paired with a PRECHECK: result -> PRECHECK_RUN 1" "$(detect_precheck_run "$(printf '%s\n' \
  '{"type":"system","subtype":"init"}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"bash /p/plugin/scripts/graph-lint.sh --precheck .","description":"lint with the pre-check"}}]}}' \
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"PRECHECK:\nGATE_CONTEXT THEORY-001 2 completed experiments\nprecheck: silent\n\ngraph-lint: 12 node(s) in ./graph\nclean: no integrity problems found.\n\n0 error(s), 0 warning(s)."}]}]}}' \
  '{"type":"result","subtype":"success","result":"done"}')")" 1
sc "--precheck only inside a tool_result (the skill text) -> PRECHECK_RUN 0" "$(detect_precheck_run "$(printf '%s\n' \
  '{"type":"system","subtype":"init"}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/p/plugin/skills/research-graph/SKILL.md"}}]}}' \
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"run graph-lint.sh --precheck . and quote the PRECHECK: block in the footer"}]}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"bash /p/plugin/scripts/graph-lint.sh .","description":"lint"}}]}}' \
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"graph-lint: 12 node(s) in ./graph\nclean: no integrity problems found."}]}}' \
  '{"type":"result","subtype":"success","result":"done"}')")" 0
sc "--precheck tool_use whose result never arrived -> PRECHECK_RUN 0" "$(detect_precheck_run "$(printf '%s\n' \
  '{"type":"system","subtype":"init"}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"bash /p/plugin/scripts/graph-lint.sh --precheck .","description":"lint"}}]}}' \
  '{"type":"result","subtype":"success","result":"done"}')")" 0
sc "--precheck misplaced (usage error) -> PRECHECK_RUN 0" "$(detect_precheck_run "$(printf '%s\n' \
  '{"type":"system","subtype":"init"}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"bash /p/plugin/scripts/graph-lint.sh . --precheck","description":"lint"}}]}}' \
  '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"usage: graph-lint.sh [--explain] [--precheck] [repo-dir] [NODE-ID ...]   (flags must come before any other argument)"}]}}' \
  '{"type":"result","subtype":"success","result":"done"}')")" 0

# NO_WRITE: a synthetic graph edit changes the hash (the detector would fail the run).
mk_conclude "$T/nw"; h0=$(graphhash "$T/nw"); h1=$(graphhash "$T/nw")
sc "untouched graph hashes the same twice (NO_WRITE 1)" "$([ "$h0" = "$h1" ] && echo 1 || echo 0)" 1
sed -i 's/^status: shelved$/status: backtest/' "$T/nw/graph/THEORY-002.md"; h2=$(graphhash "$T/nw")
sc "a synthetic status edit changes the hash (NO_WRITE 0)" "$([ "$h0" = "$h2" ] && echo 1 || echo 0)" 0

# FIRED_ONLY on the fired-trigger fixture
mk_fired_trigger "$T/ft"; FT_BLOCK="$(expected_block "$T/ft")"
sc "fired-trigger fixture's PRECHECK block carries FIRED for the deferred idea" "$(printf '%s\n' "$FT_BLOCK" | grep -c "^FIRED $DEFERRED_ID EXP-002 complete\$")" 1
sc "idea surfaced, FIRED quoted -> FIRED_ONLY 1" "$(printf '%s\n' 'Propose the SPLADE swap now that hybrid finished.' "$FOOTER_HDR" 'Pre-check:' "$FT_BLOCK" 'Verdict rests on: IDEA-002' | detect_fired_only)" '1(surfaced)'
sc "idea surfaced, block quoted without its FIRED line -> FIRED_ONLY 0" "$(printf '%s\n' 'Propose the learned sparse swap.' "$FOOTER_HDR" 'Pre-check:' "$(printf '%s\n' "$FT_BLOCK" | grep -v '^FIRED')" 'Verdict rests on: IDEA-002' | detect_fired_only)" '0[surfaced-without-FIRED]'
sc "idea absent from the body -> FIRED_ONLY 1" "$(printf '%s\n' 'Run the reranker gate next.' "$FOOTER_HDR" 'Pre-check:' 'precheck: silent' 'Verdict rests on: EXP-003' | detect_fired_only)" '1(absent)'

# Fixture guards: each fixture lints with zero errors and its pre-check reads as designed.
for fx in $ALL_FIXTURES; do
  d="$T/guard_$fx"; mkfix "$fx" "$d"
  lint_out=$(bash "$LINT" --precheck "$d" 2>&1); lint_rc=$?
  [ "$lint_rc" -eq 0 ] && ok "fixture $fx lints with no errors" || no "fixture $fx lints with no errors" "$(printf '%s' "$lint_out" | grep -E '^  E ' | head -3)"
done
sc "conclude fixture's pre-check is silent" "$(expected_block "$T/guard_conclude" | grep -c '^precheck: silent$')" 1
sc "unbounded-null fixture's pre-check is silent" "$(expected_block "$T/guard_unbounded-null" | grep -c '^precheck: silent$')" 1
# The skill's "nothing at all is open" clause: no open idea, no planned or running experiment, no
# deferred item. The deployed theory (live_full) still counts as not shelved under GROUNDS_OK, so a
# continue there resting on it is grounded by that rule; the conclude rate is what is reported.
sc "conclude fixture has nothing open, planned, running, or deferred" "$(grep -lE '^status: (open|planned|running|deferred)$' "$T/guard_conclude"/graph/*.md | grep -c .)" 0
sc "continue-no-planned has no planned or running experiment" "$(grep -lE '^status: (planned|running)$' "$T/guard_continue-no-planned"/graph/*.md | grep -c .)" 0
sc "continue-no-planned still has an open idea" "$(grep -lE '^status: open$' "$T/guard_continue-no-planned"/graph/*.md | grep -c .)" 2
sc "unbounded-null's only experiment carries no bound" "$(grep -c '^bound:' "$T/guard_unbounded-null/graph/EXP-001.md")" 0
sc "decoy's distinctive claim sits on the continue fixture" "$(grep -c 'nothing left to run here' "$T/guard_continue/graph/$DECOY.md")" 1

[ "$fail" -eq 0 ] || { echo "detector self-checks failed ($fail); the measurement would be meaningless."; exit 1; }
[ "$SELFCHECK_ONLY" -eq 0 ] || { echo "self-checks passed ($pass); --selfcheck-only set, no model call made."; exit 0; }

# --- Model arm ---
# One natural-language prompt for every fixture. It is the phrasing the skill names as a trigger
# and it hints at no verdict: the conclude fixture gets the same question as the others.
PROMPT='Just opened this project back up. Where does this stand, and what should we run next?'

run_once(){ # $1=fixture dir -> stream-json on stdout; rc 1 when the run errored or has no result event
  local dir="$1" out rc
  out=$(cd "$dir" && claude -p "$PROMPT" \
        --output-format stream-json --verbose --dangerously-skip-permissions \
        ${MODEL:+--model "$MODEL"} --plugin-dir "$REPO/plugin" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | grep -q '"type":"result"'; then return 1; fi
  printf '%s' "$out"
}

echo "== /tendrel:next verdict contract, N=$N per fixture, model=${MODEL:-default} =="
for fx in $FIXTURES; do
  expect=$(expect_of "$fx")
  case "$fx" in continue|continue-no-planned|unbounded-null) has_nfs=1;; *) has_nfs=0;; esac   # where NO_FALSE_STOP is a gate
  case "$fx" in continue|continue-no-planned) has_decoy=1;; *) has_decoy=0;; esac               # where EXP-004 is the decoy
  echo "== fixture $fx (honest verdict: $expect) =="
  errs=0; vone=0; nfs=0; grounds=0; nowrite=0; prun=0; pquoted=0; fired=0; bodyfail=0; groundfail=0; neg=0; decoy=0
  v_continue=0; v_conclude=0; v_wait=0
  for i in $(seq 1 "$N"); do
    d="$T/${fx}_$i"; mkfix "$fx" "$d"
    before=$(graphhash "$d")
    stream=$(run_once "$d") || { echo "  $fx run $i: RUN:ERR (claude exit or no result event)"; errs=$((errs+1)); continue; }
    after=$(graphhash "$d")
    txt=$(result_text "$stream")
    [ -z "$txt" ] && { echo "  $fx run $i: RUN:ERR (no result text)"; errs=$((errs+1)); continue; }
    # verdict
    words=$(printf '%s\n' "$txt" | verdict_words); vc=$(printf '%s\n' "$words" | grep -c .)
    case "$vc" in 1) vone=$((vone+1)); vword="$words";; 0) vword=none;; *) vword="multi($(printf '%s' "$words" | tr '\n' ','))";; esac
    printf '%s\n' "$words" | grep -q '^continue$' && v_continue=$((v_continue+1))
    printf '%s\n' "$words" | grep -q '^conclude$' && v_conclude=$((v_conclude+1))
    printf '%s\n' "$words" | grep -q '^wait$' && v_wait=$((v_wait+1))
    if printf '%s\n' "$words" | grep -qE '^(conclude|wait)$'; then nfs_s=" NO_FALSE_STOP:0"; else nfs=$((nfs+1)); nfs_s=" NO_FALSE_STOP:1"; fi
    [ "$has_nfs" -eq 1 ] || nfs_s=""
    # grounds: the observed verdict sets the policy; with no single verdict, the fixture's honest one does
    pol="$vword"; case "$pol" in continue|conclude|wait) ;; *) pol="$expect";; esac
    g=$(printf '%s\n' "$txt" | grounds_check "$d" "$pol" "$DECOY"); [ "$g" = 1 ] && grounds=$((grounds+1))
    [ "$has_decoy" -eq 1 ] && printf '%s\n' "$txt" | grounds_ids | grep -qx "$DECOY" && decoy=$((decoy+1))
    # write, pre-check run, quoted, fired
    if [ "$before" = "$after" ]; then nowrite=$((nowrite+1)); nw_s="NO_WRITE:1"; else nw_s="NO_WRITE:0"; fi
    pr=$(detect_precheck_run "$stream"); [ "$pr" = 1 ] && prun=$((prun+1))
    pq=$(printf '%s\n' "$txt" | detect_quoted "$d"); [ "$pq" = 1 ] && pquoted=$((pquoted+1))
    fo=""; if [ "$fx" = fired-trigger ]; then fo=$(printf '%s\n' "$txt" | detect_fired_only); case "$fo" in 1*) fired=$((fired+1));; esac; fo=" FIRED_ONLY:$fo"; fi
    # the original two rules and the soft negative-grounding heuristic
    bids="$(printf '%s\n' "$txt" | body_ids | tr '\n' ',')"
    fids="$(printf '%s\n' "$txt" | footer_ids)"
    if [ -n "$bids" ]; then bodyfail=$((bodyfail+1)); bstat="BODY-IDS[$bids]"; else bstat="body-clean"; fi
    gbad=""; for id in $fids; do is_real "$d" "$id" || gbad="$gbad $id"; done
    if [ -z "$fids" ]; then groundfail=$((groundfail+1)); gstat="GROUND[empty-footer]"
    elif [ -n "$gbad" ]; then groundfail=$((groundfail+1)); gstat="GROUND[hallucinated:$gbad]"
    else gstat="grounded"; fi
    # Detect real negative-grounding language, NOT the contract's own boilerplate ("what to skip",
    # "skippable" footer), which would otherwise match every output and make the metric meaningless.
    if printf '%s' "$txt" | grep -qiE 'ruled out|already (ruled|tried|tested|shown|showed|found)|do not repeat|don.t repeat|dead end|regressed|did not (work|help)'; then
      neg=$((neg+1)); nstat="neg+"; else nstat="neg-"; fi
    echo "  $fx run $i: verdict=$vword VERDICT_ONE:$([ "$vc" -eq 1 ] && echo 1 || echo 0)$nfs_s GROUNDS_OK:$g $nw_s PRECHECK_RUN:$pr PRECHECK_QUOTED:$pq$fo $bstat $gstat $nstat"
  done
  done_n=$((N-errs))
  echo "  ==> $fx: verdicts continue $v_continue / conclude $v_conclude / wait $v_wait | VERDICT_ONE $vone/$done_n$([ "$has_nfs" -eq 1 ] && echo " | NO_FALSE_STOP $nfs/$done_n") | GROUNDS_OK $grounds/$done_n | NO_WRITE $nowrite/$done_n | PRECHECK_RUN $prun/$done_n | PRECHECK_QUOTED $pquoted/$done_n$([ "$fx" = fired-trigger ] && echo " | FIRED_ONLY $fired/$done_n")$([ "$has_decoy" -eq 1 ] && echo " | decoy cited $decoy/$done_n") | ID-free body $((done_n-bodyfail))/$done_n | grounded footer $((done_n-groundfail))/$done_n | negative-grounding $neg/$done_n (soft) | errored $errs/$N"
  if [ "$errs" -gt 0 ]; then no "$fx: all $N runs completed" "$errs run(s) errored; the measurement is incomplete and certifies nothing"; continue; fi
  [ "$vone" -eq "$N" ] && ok "$fx: VERDICT_ONE (hard) $N/$N" || no "$fx: VERDICT_ONE (hard)" "$((N-vone))/$N runs had zero or several Verdict: lines"
  [ "$bodyfail" -eq 0 ] && ok "$fx: ID-free body (hard) $N/$N" || no "$fx: ID-free body (hard)" "$bodyfail/$N leaked node IDs into the body"
  [ "$groundfail" -eq 0 ] && ok "$fx: grounded footer (hard) $N/$N" || no "$fx: grounded footer (hard)" "$groundfail/$N had an empty or hallucinated footer"
  case "$fx" in
    continue|continue-no-planned|unbounded-null)
      [ "$nfs" -eq "$N" ] && ok "$fx: NO_FALSE_STOP (hard) $N/$N" || no "$fx: NO_FALSE_STOP (hard)" "$((N-nfs))/$N runs said conclude or wait on a graph whose honest verdict is continue";;
  esac
  case "$fx" in
    continue|continue-no-planned)
      [ "$grounds" -eq "$N" ] && ok "$fx: GROUNDS_OK (hard) $N/$N" || no "$fx: GROUNDS_OK (hard)" "$((N-grounds))/$N runs rested the verdict on no real non-terminal node (empty, unreal, decoy-only, or settled nodes only)";;
  esac
  case "$fx" in
    conclude)
      [ "$nowrite" -eq "$N" ] && ok "$fx: NO_WRITE under reconcile = auto (hard) $N/$N" || no "$fx: NO_WRITE under reconcile = auto (hard)" "$((N-nowrite))/$N runs changed graph/; a verdict is advice, never drift"
      echo "  NOTE: $fx conclude rate $v_conclude/$N (reported, not asserted)";;
  esac
done

echo "---"; echo "next-integration: PASS=$pass FAIL=$fail"
echo "Targets: VERDICT_ONE, ID-free body, grounded footer on every fixture, NO_FALSE_STOP on continue, continue-no-planned, and unbounded-null, GROUNDS_OK on continue and continue-no-planned, NO_WRITE on conclude (hard); conclude rate, PRECHECK_RUN, PRECHECK_QUOTED, FIRED_ONLY, decoy citations, and negative grounding are rates, reported not asserted."
[ "$fail" -eq 0 ]
