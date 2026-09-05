#!/usr/bin/env bash
# Deterministic graph-integrity lint for tendrel. Read-only: it never writes to graph/.
# Usage: bash graph-lint.sh [--explain] [repo-dir] [NODE-ID ...]   (default: current directory)
# With --explain, every edge of the named nodes (all nodes when none are named) prints first, one
# line each as `SRC rel TARGET "summary"`, where the summary is the first line of whatever the edge
# points at, so a wrong target reads wrong at a glance; the normal report and exit code follow,
# unchanged. Exits non-zero when any ERROR-severity violation exists. WARNINGS print but do not fail,
# so this is safe as a CI gate (a broken graph fails; an advisory nudge does not).
# Checks: dangling edges (a target is a node ID or a repo-relative path, and either must resolve),
# unreadable edges, invalid kind/status, duplicate IDs, depends_on cycles, mutual or
# self-referencing invalidated_by/supersedes/part_of edges, transitive invalidation consistency,
# and that every `provenance:` path a node declares resolves.
set -uo pipefail
# `--explain` is the only flag and is consumed first. After it, the first argument is the repo dir
# only when it names an existing directory; otherwise every argument is a node ID and the repo dir
# stays `.`, so `cd repo && graph-lint.sh --explain NODE-008` works without naming the root. Without
# the flag the one optional positional is the repo dir, exactly as before.
EXPLAIN=0; EXPLAIN_IDS=""
if [ "${1:-}" = "--explain" ]; then
  EXPLAIN=1; shift
  ROOT="."
  if [ $# -gt 0 ] && [ -d "$1" ]; then ROOT="$1"; shift; fi
  EXPLAIN_IDS="$*"
else
  ROOT="${1:-.}"
fi

ROOT="$ROOT" EXPLAIN="$EXPLAIN" EXPLAIN_IDS="$EXPLAIN_IDS" python3 <<'PY'
import os, sys, glob, re, subprocess, functools

root = os.environ.get("ROOT", ".")
graphdir = os.path.join(root, "graph")
explain = os.environ.get("EXPLAIN") == "1"
explain_ids = list(dict.fromkeys(os.environ.get("EXPLAIN_IDS", "").split()))   # scope, in given order

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
FM_RE = re.compile(r"^---\n(.*?)\n---\n?(.*)$", re.S)   # frontmatter fences, then the body

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

def escapes_repo(rel):
    """True for an absolute path or one that climbs above the repo root; every path check below
    rejects those before touching the filesystem."""
    return os.path.isabs(rel) or os.path.normpath(rel).split(os.sep)[0] == ".."

@functools.lru_cache(maxsize=None)
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

def target_state(rel):
    """How git sees a repo-relative path, and whether it is on disk. The edge-target and provenance
    loops map this pair to different outcomes on purpose (an ignored edge target is silent, an
    ignored provenance path warns), so only the lookup is shared."""
    return git_status(rel), os.path.exists(os.path.join(root, rel))

errors, warnings = [], []
nodes = {}          # id -> record (last-wins for lookups; duplicates flagged separately)
id_files = {}       # id -> [files]

for path in sorted(glob.glob(os.path.join(graphdir, "*.md"))):
    name = os.path.basename(path)
    text = open(path, encoding="utf-8", errors="replace").read()
    m = FM_RE.match(text)
    if not m:
        errors.append(f"{name}: malformed frontmatter (missing '---' fences)")
        continue
    fm, body = m.group(1), m.group(2)
    def f(key):
        mm = re.search(rf"^{key}:\s*(.+)$", fm, re.M)
        return mm.group(1).strip().strip('"') if mm else ""
    nid = f("id") or name[:-3]
    # Read each edge from a single line. Tolerant of harmless variation the agent or a human
    # might introduce: extra spaces around the colons, extra keys after `to:` (the `[^\s},]+`
    # target capture stops at a comma or brace, so `{rel: depends_on, to: NODE-4, weight: 1}`
    # still resolves `NODE-4`), and YAML quotes around the target. The capture keeps the quotes,
    # so `to: "NODE-004"` is stripped to `NODE-004` here, once, before anything classifies or
    # compares it; an empty quoted target keeps its quotes so it still reads as a missing path
    # below and not as the repo root. What it deliberately does NOT accept is an edge split across
    # lines (block-style YAML); those are caught as unreadable below. `.` never crosses a newline
    # here (no DOTALL), so each match stays within one line.
    edges = [(rel, to.strip('"\'') or to)
             for rel, to in re.findall(r"rel\s*:\s*([a-z_]+).*?\bto\s*:\s*([^\s},]+)", fm)]
    id_files.setdefault(nid, []).append(name)
    nodes[nid] = {"file": name, "fm": fm, "kind": f("kind"), "status": f("status"),
                  "body": body.strip(), "edges": edges, "provenance": provenance_paths(fm)}

SUMMARY_WIDTH = 80

@functools.lru_cache(maxsize=None)
def edge_summary(to):
    """What --explain prints beside an edge target: the first non-blank line of the thing the edge
    points at, so a wrong target reads wrong at a glance. A node target (the quote-stripped `to`
    the loop above resolved) gives its first body line; a repo-relative file gives its first
    non-blank line after any leading frontmatter block, read with the same fence rule as a node.
    `(empty body)` when there is no such line, `(missing)` when the target is neither a node nor a
    file the lint would accept (absolute and `..` paths included, so this never reads outside the
    repo). Cut at SUMMARY_WIDTH characters with a trailing `...` so a long first paragraph stays one
    line. Deterministic and read-only: the same graph always renders the same lines."""
    if to in nodes:
        text = nodes[to]["body"]
    elif escapes_repo(to):
        return "(missing)"
    else:
        path = os.path.join(root, to)
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except IsADirectoryError:
            return "(directory)"
        except OSError:
            return "(missing)"
        if "\x00" in text:
            return "(binary file)"
        m = FM_RE.match(text)
        if m:
            text = m.group(2)
    line = next((ln.strip() for ln in text.splitlines() if ln.strip()), "")
    if not line:
        return "(empty body)"
    return line[:SUMMARY_WIDTH] + "..." if len(line) > SUMMARY_WIDTH else line

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

# edge checks: dangling references and invalidation consistency. A target has exactly two readings:
# it matches the node-ID pattern and must name a node in graph/, or it is a repo-relative path
# (docs/plans/x.md, wiki/page.md, results/a.md) and must resolve the way a provenance path does,
# through the same git_status() outcomes, with one difference. A path the repo .gitignore matches is
# silent here, present or absent, where provenance warns: a link to a private plan document is
# legitimate and permanent, and a warning nobody can act on is the hygiene problem this check
# exists to remove. There is no third reading. A target that is neither a node nor a file is an
# error that names both readings, so a lowercase node-ID typo (`node-004`) fails closed instead of
# drifting past as an advisory. With no git at all, plain existence decides.
for nid, rec in nodes.items():
    for rel, to in rec["edges"]:
        # An existing node is a node target even when its ID strays from the PREFIX-NNN pattern;
        # the lint never validated IDs themselves, so a graph with odd IDs must not start failing
        # on every edge to them.
        if NODE_RE.match(to) or to in nodes:
            if to not in nodes:
                errors.append(f"{nid}: dangling {rel} edge to missing node {to}")
        elif escapes_repo(to):
            errors.append(f"{nid}: {rel} edge target '{to}' must be repo-relative "
                          "(no absolute paths, no '..')")
        else:
            status, exists = target_state(to)
            if status != "ignored" and not exists:
                errors.append(f"{nid}: {rel} edge target {to}: no node with this ID and no such file")
            elif status == "untracked":
                warnings.append(f"{nid}: {rel} edge target {to} exists but is not tracked by git; "
                                "a clean checkout will report it missing")
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
# read-only, the same shape as the path-target edge check above. A path git ignores (raw/, work/,
# data dumps) is a WARNING, not an error: it resolves on the machine that produced it and vanishes
# from a clean checkout, so an error would turn the lint red in exactly one environment, which is
# the kind of gate people learn to ignore. (An ignored edge target is silent instead: a cited
# number should be reproducible from a clean checkout, a link is only a pointer.) Missing and not
# ignored is an error: the node cites something that is not there.
for nid, rec in nodes.items():
    for p in rec["provenance"]:
        if p.startswith("?unterminated list:"):
            errors.append(f"{nid}: couldn't read provenance in graph/{rec['file']}. "
                          "Write it as a closed inline list, e.g.  provenance: [results/a.md]")
            continue
        if escapes_repo(p):
            errors.append(f"{nid}: provenance path '{p}' must be repo-relative "
                          "(no absolute paths, no '..')")
            continue
        status, exists = target_state(p)
        if status == "ignored":
            warnings.append(f"{nid}: provenance path {p} is ignored by git; it resolves here "
                            "but not from a clean checkout")
        elif not exists:
            errors.append(f"{nid}: provenance path {p} does not exist")
        elif status == "untracked":
            warnings.append(f"{nid}: provenance path {p} exists but is not tracked by git; "
                            "a clean checkout will report it missing")

# mutual-pair and self-loop checks for the relations where direction carries the meaning.
# `A invalidated_by B` and `B invalidated_by A` cannot both be true (the same goes for supersedes
# and part_of), so a reversed pair means at least one edge is wrong: an error, not a nudge. Report
# it once per relation and unordered pair, with the relation in the dedupe key so two relations
# reversed between the same nodes are two findings. A self-loop is the same mistake with one node.
# Pairwise on purpose: a longer ring (A -> B -> C -> A) is not a reversed edge, and depends_on is
# left out here because its cycles already belong to the cycle detector below.
DIRECTED = ("invalidated_by", "supersedes", "part_of")
triples = {(nid, rel, to) for nid, rec in nodes.items() for rel, to in rec["edges"] if rel in DIRECTED}
seen_pairs = set()
for src, rel, dst in sorted(triples):
    if src == dst:
        errors.append(f"{src}: {rel} edge to itself; remove it.")
    elif (dst, rel, src) in triples:
        key = (rel, frozenset((src, dst)))
        if key in seen_pairs:
            continue
        seen_pairs.add(key)
        errors.append(f"{src} / {dst}: mutual {rel}, each claims the other. "
                      "Direction carries the meaning here; remove whichever edge is reversed.")

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

# explain: one line per edge with the summary of its target, printed before the report so the
# report keeps its shape for callers that grep it. Rendering only: nothing here appends to errors
# or warnings, and the exit code below is what it would be without the flag. Source nodes come in
# file order, the same order `nodes` was built in; with a scope, only the named nodes' edges print.
# A named ID that is not a node gets one note and is skipped, so a typo in the scope is visible
# instead of rendering nothing and looking like a node without edges.
if explain:
    notes = [f"  (no node {i})" for i in explain_ids if i not in nodes]
    lines = [f'  {nid} {rel} {to} "{edge_summary(to)}"'
             for nid, rec in nodes.items() if not explain_ids or nid in explain_ids
             for rel, to in rec["edges"]]
    print(f"EXPLAIN ({len(lines)} edges):")
    for ln in notes + lines:
        print(ln)
    print()

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
