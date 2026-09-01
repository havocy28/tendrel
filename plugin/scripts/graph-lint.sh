#!/usr/bin/env bash
# Deterministic graph-integrity lint for tendrel. Read-only: it never writes to graph/.
# Usage: bash graph-lint.sh [repo-dir]   (default: current directory)
# Exits non-zero when any ERROR-severity violation exists. WARNINGS print but do not fail,
# so this is safe as a CI gate (a broken graph fails; an advisory nudge does not).
# Checks: dangling edges, unreadable edges, invalid kind/status, duplicate IDs, depends_on cycles,
# transitive invalidation consistency, and that every `provenance:` path a node declares resolves.
set -uo pipefail
ROOT="${1:-.}"

ROOT="$ROOT" python3 <<'PY'
import os, sys, glob, re, subprocess

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

def provenance_paths(fm):
    """Read the `provenance:` key: a flat list of repo-relative paths naming the artifacts a node's
    numbers come from. Accepts the inline form (`provenance: [results/a.md, results/b.tsv]`), the
    block form (one `- path` per line under the key), and a bare scalar (`provenance: results/a.md`)
    as a single path. Returns [] when the key is absent, so graphs that never declare provenance
    are untouched by the check."""
    paths, lines = [], fm.splitlines()
    def clean(x):
        return re.sub(r"\s+#.*$", "", x).strip().strip('"\'')   # drop a trailing YAML comment
    for i, ln in enumerate(lines):
        # Tolerate a space before the colon: the edge regex once silently skipped `rel :`, and a
        # skipped key here would mean a broken citation lints clean.
        m = re.match(r"^provenance\s*:\s*(.*)$", ln)
        if not m:
            continue
        val = m.group(1).strip()
        if val.startswith("["):
            end = val.rfind("]")
            if end < 0:
                return [f"?unterminated list: {val}"]     # surfaced as an unreadable value below
            paths += [clean(x) for x in val[1:end].split(",") if clean(x)]
        elif val:
            v = clean(val)
            if v and v not in ("null", "~"):
                paths.append(v)
        else:
            for nxt in lines[i + 1:]:
                if re.match(r"^\S", nxt):      # next top-level key ends the block
                    break
                mm = re.match(r"^\s*-\s*(.+?)\s*$", nxt)
                if mm and clean(mm.group(1)):
                    paths.append(clean(mm.group(1)))
        break
    return paths

def git_status(rel):
    """How git sees `rel` under root: "ignored" (matched by a .gitignore committed in the repo),
    "untracked" (present on disk but not tracked), "tracked", or "nogit" (no git, no repo).
    Only repo .gitignore files count as ignore sources: core.excludesFile and .git/info/exclude
    are per-machine, and a rule that lives on one machine would make the lint read differently
    there than in a clean checkout, which is the property this check exists to keep."""
    try:
        r = subprocess.run(["git", "-C", root, "check-ignore", "-v", "--non-matching", "--", rel],
                           capture_output=True, text=True)
    except OSError:
        return "nogit"
    if r.returncode == 128:
        return "nogit"
    src = r.stdout.split(":", 1)[0].strip() if r.stdout else ""
    if r.returncode == 0 and src and not os.path.isabs(src) and os.path.basename(src) == ".gitignore":
        return "ignored"
    try:
        t = subprocess.run(["git", "-C", root, "ls-files", "--error-unmatch", "--", rel],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return "nogit"
    return "tracked" if t.returncode == 0 else "untracked"

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
                  "body": body.strip(), "edges": edges, "provenance": provenance_paths(fm)}

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

# provenance checks: every artifact a node declares must resolve on disk. Deterministic and
# read-only, the same shape as the wiki/ edge check above. A path git ignores (raw/, work/, data
# dumps) is a WARNING, not an error: it resolves on the machine that produced it and vanishes from
# a clean checkout, so an error would turn the lint red in exactly one environment, which is the
# kind of gate people learn to ignore. Missing and not ignored is an error: the node cites
# something that is not there.
for nid, rec in nodes.items():
    for p in rec["provenance"]:
        if p.startswith("?unterminated list:"):
            errors.append(f"{nid}: couldn't read provenance in graph/{rec['file']}. "
                          "Write it as a closed inline list, e.g.  provenance: [results/a.md]")
            continue
        if os.path.isabs(p) or os.path.normpath(p).split(os.sep)[0] == "..":
            errors.append(f"{nid}: provenance path '{p}' must be repo-relative "
                          "(no absolute paths, no '..')")
            continue
        status = git_status(p)
        exists = os.path.exists(os.path.join(root, p))
        if status == "ignored":
            warnings.append(f"{nid}: provenance path {p} is ignored by git; it resolves here "
                            "but not from a clean checkout")
        elif not exists:
            errors.append(f"{nid}: provenance path {p} does not exist")
        elif status == "untracked":
            warnings.append(f"{nid}: provenance path {p} exists but is not tracked by git; "
                            "a clean checkout will report it missing")

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
