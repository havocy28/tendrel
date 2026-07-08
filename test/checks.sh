#!/usr/bin/env bash
# Tier-1 static checks. No model needed. Fast structural + consistency gate.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  $2"; fail=$((fail+1)); }

# 1. plugin.json valid + has a version
if python3 -c "import json,sys; d=json.load(open('plugin/.claude-plugin/plugin.json')); sys.exit(0 if d.get('version') else 1)" 2>/dev/null; then
  ok "plugin.json is valid JSON with a version"
else
  no "plugin.json is valid JSON with a version"
fi

# 2. shell scripts parse
for s in $(find . -name '*.sh' -not -path './.git/*'); do
  bash -n "$s" 2>/dev/null && ok "bash -n $s" || no "bash -n $s"
done

# 3. config keys referenced where expected. The report script reads only `verbosity`
#    (background is a skill-level concern); the skill and docs cover both keys.
grep -q "verbosity" plugin/scripts/session-start-report.sh \
  && ok "verbosity referenced in report script" \
  || no "verbosity referenced in report script"
for f in plugin/skills/research-graph/SKILL.md README.md docs/how-it-works.md; do
  grep -q "verbosity" "$f" && grep -q "background" "$f" \
    && ok "both config keys present in $f" \
    || no "both config keys present in $f" "verbosity/background not both found"
done

# 4. no em dashes in user-facing docs and commands (SKILL.md and spike fixtures excluded:
#    SKILL.md carries known pre-existing em dashes)
emd=0
for f in README.md CHANGELOG.md plugin/commands/*.md $(find docs -name '*.md' -not -path '*/spike-fixtures/*'); do
  if grep -q "—" "$f"; then echo "  em dash in $f"; emd=1; fi
done
[ "$emd" -eq 0 ] && ok "no em dashes in README + docs + commands" || no "no em dashes in README + docs + commands"

# 5. relative markdown links resolve to real files
python3 - <<'PY'
import re, os, sys, glob
bad = []
files = ["README.md"] + glob.glob("docs/**/*.md", recursive=True)
for f in files:
    base = os.path.dirname(f)
    for m in re.finditer(r"\[[^\]]+\]\(([^)]+)\)", open(f, encoding="utf-8").read()):
        link = m.group(1).split("#")[0].strip()
        if not link or link.startswith(("http://","https://","mailto:")):
            continue
        target = os.path.normpath(os.path.join(base, link))
        if not os.path.exists(target):
            bad.append(f"{f} -> {link}")
if bad:
    print("FAIL: relative links resolve")
    for b in bad: print("  " + b)
    sys.exit(1)
print("PASS: relative links resolve")
PY
[ $? -eq 0 ] && pass=$((pass+1)) || fail=$((fail+1))

echo "---"; echo "checks: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
