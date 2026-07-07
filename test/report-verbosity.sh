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

echo "---"; echo "report-verbosity: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
