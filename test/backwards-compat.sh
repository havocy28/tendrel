#!/usr/bin/env bash
# Backwards-compatibility lint sweep. Runs the graph lint against a corpus of example and
# older-vintage graphs and asserts each lints clean. Adding a backwards-compat case is dropping a
# graph folder under test/compat-graphs/. Deterministic; no model needed.
set -uo pipefail
shopt -s nullglob
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$REPO/plugin/scripts/graph-lint.sh"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  $2"; fail=$((fail+1)); }

# Sweep one graph root. Returns: 0 clean, 2 vacuous (no nodes -> mis-nested), 1 lint error.
# The vacuous guard matters because graph-lint.sh exits 0 on a dir with no graph/ subdir, so a
# fixture dropped one level off would otherwise pass while testing nothing.
sweep_root(){
  local root="$1"
  local files=( "$root"/graph/*.md )   # nullglob -> empty array when no graph/ or no nodes
  [ "${#files[@]}" -eq 0 ] && return 2
  bash "$LINT" "$root" >/dev/null 2>&1
}

check(){   # check <root> <label>
  local root="$1" label="$2" rc
  local files=( "$root"/graph/*.md )
  local n=${#files[@]}
  sweep_root "$root"; rc=$?
  case "$rc" in
    0) ok "$label lints clean ($n node(s))" ;;
    2) no "$label ($root)" "no graph/*.md - mis-nested fixture? (vacuous-pass guard)" ;;
    *) no "$label ($root)" "lint failed (exit $rc): $(bash "$LINT" "$root" 2>&1 | tail -3)" ;;
  esac
}

# Corpus: dedicated backwards-compat fixtures, then the showcase examples (which double as coverage).
for root in "$REPO"/test/compat-graphs/*/; do check "${root%/}" "compat:$(basename "${root%/}")"; done
for root in "$REPO"/examples/*/;            do check "${root%/}" "example:$(basename "${root%/}")"; done

# Negative control: a deliberately broken graph must be flagged, proving the sweep asserts.
d="$(mktemp -d)"; mkdir -p "$d/graph"
printf '%s\n' '---
id: NODE-001
kind: pipeline_node
status: untested
edges:
  - {rel: depends_on, to: NODE-999}
---
Dangling edge.' > "$d/graph/NODE-001.md"
sweep_root "$d"; rc=$?
[ "$rc" -eq 1 ] && ok "negative control: broken graph flagged (exit 1)" \
  || no "negative control" "expected lint-error exit 1, got $rc"

# Vacuous-pass guard: markdown not under graph/ must resolve to zero nodes (caught, not passed).
d2="$(mktemp -d)"; printf 'x\n' > "$d2/NODE-001.md"
sweep_root "$d2"; rc=$?
[ "$rc" -eq 2 ] && ok "vacuous-pass guard: mis-nested root caught (would fail the sweep)" \
  || no "vacuous-pass guard" "expected vacuous(2), got $rc"

echo "---"; echo "backwards-compat: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
