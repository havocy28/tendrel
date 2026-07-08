#!/usr/bin/env bash
# Deterministic graph-integrity lint for tendrel. Read-only: it never writes to graph/.
# Usage: bash graph-lint.sh [repo-dir]   (default: current directory)
# Exits non-zero when any ERROR-severity violation exists. WARNINGS print but do not fail,
# so this is safe as a CI gate (a broken graph fails; an advisory nudge does not).
set -uo pipefail
ROOT="${1:-.}"

ROOT="$ROOT" python3 <<'PY'
import os, sys, glob, re

root = os.environ.get("ROOT", ".")
graphdir = os.path.join(root, "graph")

if not os.path.isdir(graphdir):
    print("graph-lint: no graph/ directory here; repo is not scaffolded for tendrel. Nothing to lint.")
    sys.exit(0)

KINDS = {"experiment", "theory", "pipeline_node", "decision", "idea", "observation"}
STATUS = {
    "experiment":    {"planned", "running", "complete", "abandoned"},
    "theory":        {"idea", "backtest", "paper_trade", "live_small", "live_full", "shelved"},
    "pipeline_node": {"untested", "assumed_working", "validated", "invalidated", "blocked"},
    "decision":      {"active", "under_review", "reversed"},
    "idea":          {"open", "promoted", "dropped"},
    "observation":   set(),
}
NODE_RE = re.compile(r"^[A-Z]+-\d+$")

errors, warnings = [], []
nodes = {}          # id -> record (last-wins for lookups; duplicates flagged separately)
id_files = {}       # id -> [files]

for path in sorted(glob.glob(os.path.join(graphdir, "*.md"))):
    name = os.path.basename(path)
    text = open(path, encoding="utf-8", errors="replace").read()
    m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.S)
    if not m:
        errors.append(f"{name}: malformed frontmatter (missing '---' fences)")
        continue
    fm, body = m.group(1), m.group(2)
    def f(key):
        mm = re.search(rf"^{key}:\s*(.+)$", fm, re.M)
        return mm.group(1).strip().strip('"') if mm else ""
    nid = f("id") or name[:-3]
    edges = re.findall(r"rel:\s*([a-z_]+),\s*to:\s*([^\s}]+)", fm)
    id_files.setdefault(nid, []).append(name)
    nodes[nid] = {"file": name, "fm": fm, "kind": f("kind"), "status": f("status"),
                  "body": body.strip(), "edges": edges}

# duplicate ids
for nid, files in id_files.items():
    if len(files) > 1:
        errors.append(f"{nid}: duplicate id across {', '.join(sorted(files))}")

# per-node checks
for nid, rec in nodes.items():
    kind, status = rec["kind"], rec["status"]
    if not kind:
        errors.append(f"{nid} ({rec['file']}): missing kind")
    elif kind not in KINDS:
        errors.append(f"{nid} ({rec['file']}): invalid kind '{kind}'")
    else:
        if status and status not in STATUS[kind]:
            errors.append(f"{nid}: invalid status '{status}' for kind {kind}")
        if kind != "observation" and not status:
            warnings.append(f"{nid}: missing status")
        if kind == "experiment" and not re.search(r"^question:\s*\S", rec["fm"], re.M):
            warnings.append(f"{nid}: experiment missing 'question'")
    if not rec["body"]:
        warnings.append(f"{nid}: empty body (claimed but unlogged)")

# edge checks: dangling references and invalidation consistency
for nid, rec in nodes.items():
    for rel, to in rec["edges"]:
        if NODE_RE.match(to):
            if to not in nodes:
                errors.append(f"{nid}: dangling {rel} edge to missing node {to}")
        elif to.startswith("wiki/"):
            if not os.path.exists(os.path.join(root, to)):
                errors.append(f"{nid}: {rel} edge to missing wiki file {to}")
        else:
            warnings.append(f"{nid}: unrecognized {rel} edge target '{to}'")
        if rel == "depends_on" and to in nodes and nodes[to]["status"] == "invalidated":
            if rec["status"] != "blocked":
                errors.append(f"{nid}: depends_on invalidated node {to} but is not blocked "
                              f"(status '{rec['status'] or 'none'}')")

# depends_on cycle detection (the pipeline is meant to be a DAG)
adj = {nid: [to for rel, to in rec["edges"] if rel == "depends_on" and to in nodes]
       for nid, rec in nodes.items()}
WHITE, GRAY, BLACK = 0, 1, 2
color = {n: WHITE for n in adj}
found = []
def visit(n, stack):
    color[n] = GRAY
    stack.append(n)
    for nxt in adj.get(n, []):
        if color.get(nxt) == GRAY:
            found.append(stack[stack.index(nxt):] + [nxt])
        elif color.get(nxt) == WHITE:
            visit(nxt, stack)
    stack.pop()
    color[n] = BLACK
for n in list(adj):
    if color[n] == WHITE:
        visit(n, [])
seen = set()
for cyc in found:
    key = frozenset(cyc)
    if key in seen:
        continue
    seen.add(key)
    errors.append("depends_on cycle: " + " -> ".join(cyc))

# report
print(f"graph-lint: {len(nodes)} node(s) in {graphdir}")
if errors:
    print(f"\nERRORS ({len(errors)}):")
    for e in errors:
        print(f"  E {e}")
if warnings:
    print(f"\nWARNINGS ({len(warnings)}):")
    for w in warnings:
        print(f"  W {w}")
if not errors and not warnings:
    print("clean: no integrity problems found.")
print(f"\n{len(errors)} error(s), {len(warnings)} warning(s).")
sys.exit(1 if errors else 0)
PY
