#!/usr/bin/env bash
# Tier-1 automated test for U1 (SessionStart report verbosity). No model needed.
# Asserts the verbosity branching in plugin/scripts/session-start-report.sh by feeding
# synthetic SessionStart payloads (cwd read from JSON) against fixture repos.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/plugin/scripts/session-start-report.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/anom/graph" "$T/clean/graph" "$T/nograph"

# anom: an empty-body node, a dangling depends_on, an open theory, an invalidated node
cat > "$T/anom/graph/OBS-001.md" <<'EOF'
---
id: OBS-001
kind: observation
---
EOF
cat > "$T/anom/graph/NODE-001.md" <<'EOF'
---
id: NODE-001
kind: pipeline_node
status: invalidated
edges:
  - {rel: depends_on, to: NODE-999}
---
Body.
EOF
cat > "$T/anom/graph/THEORY-001.md" <<'EOF'
---
id: THEORY-001
kind: theory
status: backtest
---
Body.
EOF
cat > "$T/clean/graph/EXP-001.md" <<'EOF'
---
id: EXP-001
kind: experiment
status: complete
---
Body.
EOF

run(){ printf '{"cwd":"%s"}' "$1" | bash "$SCRIPT"; }
cfg(){ printf '%s\n' "$2" > "$1/.research-graph"; }
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; echo "  $2"; fail=$((fail+1)); }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "exp=[$3] got=[$2]"; }
ne(){ [ "$2" != "$3" ] && ok "$1" || no "$1" "expected difference"; }

rm -f "$T/anom/.research-graph"
NORMAL="$(run "$T/anom")"                    # no config -> normal
cfg "$T/anom" "project = x
verbosity = normal"
eq "verbosity=normal equals no-config default" "$(run "$T/anom")" "$NORMAL"
cfg "$T/anom" "verbosity = banana"
eq "malformed verbosity falls back to normal" "$(run "$T/anom")" "$NORMAL"

cfg "$T/anom" "verbosity = succinct"
S="$(run "$T/anom")"
ne "succinct differs from normal (positive-path)" "$S" "$NORMAL"
echo "$S" | grep -q "Reconcile on demand" && no "succinct drops footer" "footer present" || ok "succinct drops footer"
echo "$S" | grep -q "Open theories" && ok "succinct keeps info_lines (open theories)" || no "succinct keeps info_lines (open theories)" "absent"
echo "$S" | grep -q "Unvalidated" && ok "succinct keeps info_lines (weak nodes)" || no "succinct keeps info_lines (weak nodes)" "absent"
cfg "$T/anom" "# a comment
# verbosity: succinct | normal | off
verbosity = succinct"
eq "comment lines ignored" "$(run "$T/anom")" "$S"

cfg "$T/anom" "verbosity = off"
O="$(run "$T/anom")"
echo "$O" | grep -q "^Research graph for this project" && no "off drops header" "header present" || ok "off drops header"
echo "$O" | grep -q "WARN" && ok "off keeps confidently-wrong WARN" || no "off keeps confidently-wrong WARN" "no WARN"
echo "$O" | grep -q "Reconcile on demand" && no "off drops footer" "footer present" || ok "off drops footer"
echo "$O" | grep -q "Open theories" && no "off drops info_lines (open theories)" "present" || ok "off drops info_lines (open theories)"
echo "$O" | grep -q "Unvalidated" && no "off drops info_lines (weak nodes)" "present" || ok "off drops info_lines (weak nodes)"

cfg "$T/clean" "verbosity = off"
eq "off + clean graph emits nothing" "$(run "$T/clean")" ""

cfg "$T/nograph" "verbosity = succinct"
eq "no graph/ dir stays silent" "$(run "$T/nograph")" ""

# --- reconcile autonomy branches (v0.6.0). Deterministic coverage for the hook-carried auto
# --- instruction, per docs/solutions/testing-agent-behavior-contracts.md (validate the hook side
# --- with synthetic payloads; the headless harness cannot see it).

# infodrift: info-level drift only (an open theory), no confidently-wrong anomalies
mkdir -p "$T/infodrift/graph"
cat > "$T/infodrift/graph/THEORY-001.md" <<'EOF'
---
id: THEORY-001
kind: theory
status: backtest
---
Body.
EOF

rm -f "$T/anom/.research-graph"
NORMAL2="$(run "$T/anom")"
cfg "$T/anom" "reconcile = ask"
eq "reconcile=ask is byte-identical to no key" "$(run "$T/anom")" "$NORMAL2"
cfg "$T/anom" "reconcile = off"
eq "invalid reconcile value fails closed to ask (byte-identical)" "$(run "$T/anom")" "$NORMAL2"

cfg "$T/anom" "reconcile = auto"
A="$(run "$T/anom")"
echo "$A" | grep -q "reconcile = auto" && ok "auto+normal: footer is the auto instruction" \
  || no "auto+normal: footer is the auto instruction" "auto line absent"
echo "$A" | grep -q "Reconcile on demand" && no "auto+normal: on-demand nudge replaced" "old footer present" \
  || ok "auto+normal: on-demand nudge replaced"

cfg "$T/anom" "verbosity = succinct
reconcile = auto"
echo "$(run "$T/anom")" | grep -q "reconcile = auto" && ok "auto+succinct: instruction rides" \
  || no "auto+succinct: instruction rides" "auto line absent"

cfg "$T/anom" "verbosity = off
reconcile = auto"
echo "$(run "$T/anom")" | grep -q "reconcile = auto" && ok "auto+off+warn drift: instruction rides" \
  || no "auto+off+warn drift: instruction rides" "auto line absent"

cfg "$T/infodrift" "verbosity = off
reconcile = auto"
I="$(run "$T/infodrift")"
echo "$I" | grep -q "reconcile = auto" && ok "auto+off+info-only drift: instruction rides" \
  || no "auto+off+info-only drift: instruction rides" "auto line absent (stale-status drift silent)"
echo "$I" | grep -q "Open theories" && ok "auto+off+info-only drift: evidence lines included" \
  || no "auto+off+info-only drift: evidence lines included" "info lines absent"

cfg "$T/clean" "verbosity = off
reconcile = auto"
eq "auto+off+clean graph stays silent" "$(run "$T/clean")" ""

# --- deferred items and fired reopen triggers (0.10.0, R13 / AE8). The report shells out to
# --- graph-lint.sh --precheck beside it and reads its DEFERRED and FIRED lines; it never evaluates
# --- a trigger itself, so "fired" here is the pre-check's "fired".
has(){ echo "$2" | grep -qF -- "$3" && ok "$1" || no "$1" "missing [$3]"; }
hasnt(){ echo "$2" | grep -qF -- "$3" && no "$1" "present [$3]" || ok "$1"; }
FIRED_LINE='Deferred, trigger fired: IDEA-001 (EXP-003 complete)'

# fired: a deferred idea whose node-form trigger names a node now complete, plus an open theory so
# the off+auto branch has drift to report (and must still say nothing about the deferred item).
mkdir -p "$T/fired/graph"
cat > "$T/fired/graph/IDEA-001.md" <<'EOF'
---
id: IDEA-001
kind: idea
status: deferred
reopen_when: EXP-003 complete
---
Body.
EOF
cat > "$T/fired/graph/EXP-003.md" <<'EOF'
---
id: EXP-003
kind: experiment
status: complete
---
Body.
EOF
cp "$T/infodrift/graph/THEORY-001.md" "$T/fired/graph/THEORY-001.md"

rm -f "$T/fired/.research-graph"
F="$(run "$T/fired")"
has "fired: normal names the item and its trigger (AE8)" "$F" "$FIRED_LINE"
hasnt "fired: nothing left waiting, so no count line" "$F" "Deferred, waiting"
cfg "$T/fired" "verbosity = normal"
eq "fired: no-config default equals verbosity=normal" "$(run "$T/fired")" "$F"
cfg "$T/fired" "verbosity = succinct"
has "fired: succinct names the item and its trigger (AE8)" "$(run "$T/fired")" "$FIRED_LINE"
cfg "$T/fired" "verbosity = off"
hasnt "fired: off says nothing about deferred items (AE8)" "$(run "$T/fired")" "Deferred"
cfg "$T/fired" "verbosity = off
reconcile = auto"
FO="$(run "$T/fired")"
has "fired: off+auto still carries the instruction" "$FO" "reconcile = auto"
hasnt "fired: off+auto says nothing about deferred items (KTD6)" "$FO" "Deferred"

# waiting: an unfired node-form trigger, a text trigger, and a deferred item with no trigger are
# counted, never named as fired; a fired item beside them is named and excluded from the count.
mkdir -p "$T/waiting/graph"
cat > "$T/waiting/graph/IDEA-002.md" <<'EOF'
---
id: IDEA-002
kind: idea
status: deferred
reopen_when: EXP-003 complete
---
Body.
EOF
cat > "$T/waiting/graph/EXP-003.md" <<'EOF'
---
id: EXP-003
kind: experiment
status: planned
---
Body.
EOF
cat > "$T/waiting/graph/IDEA-003.md" <<'EOF'
---
id: IDEA-003
kind: idea
status: deferred
reopen_when: when the vendor ships the v2 assay
---
Body.
EOF
cat > "$T/waiting/graph/EXP-004.md" <<'EOF'
---
id: EXP-004
kind: experiment
status: deferred
---
Body.
EOF
rm -f "$T/waiting/.research-graph"
W="$(run "$T/waiting")"
has "waiting: three unfired items are counted" "$W" "Deferred, waiting: 3 item(s)"
hasnt "waiting: an unfired node-form trigger is never named as fired" "$W" "trigger fired"
cfg "$T/waiting" "verbosity = succinct"
has "waiting: succinct keeps the count" "$(run "$T/waiting")" "Deferred, waiting: 3 item(s)"
cfg "$T/waiting" "verbosity = off"
hasnt "waiting: off says nothing about deferred items" "$(run "$T/waiting")" "Deferred"

mkdir -p "$T/mixed/graph"
cp "$T/waiting/graph/"*.md "$T/mixed/graph/"
cat > "$T/mixed/graph/IDEA-001.md" <<'EOF'
---
id: IDEA-001
kind: idea
status: deferred
reopen_when: EXP-005 complete
---
Body.
EOF
cat > "$T/mixed/graph/EXP-005.md" <<'EOF'
---
id: EXP-005
kind: experiment
status: complete
---
Body.
EOF
M="$(run "$T/mixed")"
has "mixed: the fired item is named" "$M" "Deferred, trigger fired: IDEA-001 (EXP-005 complete)"
has "mixed: the fired item is excluded from the waiting count" "$M" "Deferred, waiting: 3 item(s)"
hasnt "mixed: the unfired node-form trigger is not named as fired" "$M" "IDEA-002 ("

# no deferred items: the existing golden is byte-identical (no new lines at all).
hasnt "no deferred items: normal output carries no deferred line" "$NORMAL" "Deferred"

# lint errors: the pre-check block prints regardless of the lint's exit code, so the fired line
# still prints on a graph whose lint fails (here a dangling depends_on, an ERROR in the lint).
mkdir -p "$T/errfired/graph"
cp "$T/fired/graph/"*.md "$T/errfired/graph/"
cp "$T/anom/graph/NODE-001.md" "$T/errfired/graph/NODE-001.md"
bash "$REPO/plugin/scripts/graph-lint.sh" "$T/errfired" >/dev/null 2>&1 \
  && no "errfired: fixture self-check (lint must fail)" "lint exited 0" || ok "errfired: fixture self-check (lint must fail)"
E="$(run "$T/errfired")"
has "errfired: fired line prints when the lint exits non-zero" "$E" "$FIRED_LINE"
has "errfired: the WARN lines are still there" "$E" "WARN depends_on -> missing node"

# fallback: a copy of the report with no graph-lint.sh beside it prints its existing lines
# unchanged, no deferred lines, exit 0, JSON still a single line.
mkdir -p "$T/alone"
cp "$SCRIPT" "$T/alone/session-start-report.sh"
rm -f "$T/fired/.research-graph"
FB="$(printf '{"cwd":"%s"}' "$T/fired" | bash "$T/alone/session-start-report.sh")"; fb_rc=$?
eq "fallback: exit 0" "$fb_rc" "0"
hasnt "fallback: no deferred lines without the lint beside the report" "$FB" "Deferred"
eq "fallback: existing lines unchanged" "$FB" "$(printf '%s' "$F" | sed "s/\\\\n$FIRED_LINE//")"
eq "fallback: JSON is a single line" "$(printf '%s\n' "$FB" | wc -l)" "1"
eq "fired: JSON is a single line" "$(printf '%s\n' "$F" | wc -l)" "1"

echo "---"; echo "report-verbosity: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
