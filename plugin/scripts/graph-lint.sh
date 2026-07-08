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

# Source of truth for the node model is the "Node kinds, statuses, IDs" table in
# plugin/skills/research-graph/SKILL.md. These sets and session-start-report.sh mirror it; if that
# table changes, update both scripts or the lint will reject valid nodes (or accept invalid ones).
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

def declared_edges(fm):
    """Count the list items under an `edges:` key (block-style: one `- ` per edge). Used to tell
    when a node declares more edges than we could read on one line, so an unreadable edge is
    surfaced rather than silently skipped. An inline flow list (`edges: [ ... ]`) returns 0 here,
    which is safe: we only ever compare `declared > parsed`, so undercounting never false-flags."""
    count, inside = 0, False
    for ln in fm.splitlines():
        if re.match(r"^edges:\s*$", ln):
            inside = True
        elif inside and re.match(r"^\S", ln):   # next top-level key ends the block
            break
        elif inside and re.match(r"^\s*-\s", ln):
            count += 1
    return count

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
    # Read each edge from a single line. Tolerant of harmless variation the agent or a human
    # might introduce: extra spaces around the colons, and extra keys after `to:` (the `[^\s},]+`
    # target capture stops at a comma or brace, so `{rel: depends_on, to: NODE-4, weight: 1}`
    # still resolves `NODE-4`). What it deliberately does NOT accept is an edge split across
    # lines (block-style YAML); those are caught as unreadable below. `.` never crosses a newline
    # here (no DOTALL), so each match stays within one line.
    edges = re.findall(r"rel\s*:\s*([a-z_]+).*?\bto\s*:\s*([^\s},]+)", fm)
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
    # Count how many edges the node declares (list items under `edges:`) versus how many we could
    # actually read on one line. An edge we cannot read is invisible to the dangling and
    # invalidation checks, so a broken graph could lint clean. Fail closed: report it as an error
    # in plain language, naming the file and the correct shape, rather than trusting it silently.
    if declared_edges(rec["fm"]) > len(rec["edges"]):
        errors.append(f"{nid}: couldn't read an edge in graph/{rec['file']}. "
                      "Write each edge on one line, e.g.  - {rel: depends_on, to: NODE-004}")

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
        # Invalidation must propagate transitively. A node that depends_on an invalidated
        # node must be blocked; a node that depends_on an already-blocked node must also be
        # blocked. Because "blocked" itself triggers the rule, a single local pass cascades the
        # whole chain (C invalidated -> B blocked -> A blocked) without a closure walk.
        if rel == "depends_on" and to in nodes and nodes[to]["status"] in ("invalidated", "blocked"):
            if rec["status"] != "blocked":
                dep_status = nodes[to]["status"]
                errors.append(f"{nid}: depends_on {dep_status} node {to} but is not blocked "
                              f"(status '{rec['status'] or 'none'}')")

# depends_on cycle detection (the pipeline is meant to be a DAG)
adj = {nid: [to for rel, to in rec["edges"] if rel == "depends_on" and to in nodes]
       for nid, rec in nodes.items()}
WHITE, GRAY, BLACK = 0, 1, 2
color = {n: WHITE for n in adj}
found = []
# Iterative DFS so a very deep depends_on chain reports cleanly instead of crashing the
# interpreter with a RecursionError. `path` mirrors the gray stack, so a back-edge to a gray
# node reconstructs the cycle in order.
for start in list(adj):
    if color[start] != WHITE:
        continue
    color[start] = GRAY
    stack = [(start, iter(adj.get(start, [])))]
    path = [start]
    while stack:
        node, it = stack[-1]
        advanced = False
        for nxt in it:
            if color.get(nxt) == GRAY:
                found.append(path[path.index(nxt):] + [nxt])
            elif color.get(nxt) == WHITE:
                color[nxt] = GRAY
                stack.append((nxt, iter(adj.get(nxt, []))))
                path.append(nxt)
                advanced = True
                break
        if not advanced:
            color[node] = BLACK
            stack.pop()
            path.pop()
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
