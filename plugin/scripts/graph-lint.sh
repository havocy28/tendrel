#!/usr/bin/env bash
# Deterministic graph-integrity lint for tendrel. Read-only: it never writes to graph/.
# Usage: bash graph-lint.sh [--explain] [--precheck] [repo-dir] [NODE-ID ...]   (default: current directory)
# With --explain, every edge of the named nodes (all nodes when none are named) prints first, one
# line each as `SRC rel TARGET "summary"`, where the summary is the first line of whatever the edge
# points at, so a wrong target reads wrong at a glance; the normal report and exit code follow,
# unchanged. With --precheck, a `PRECHECK:` block prints first (after the EXPLAIN block when both
# are given): one line per stale gate, pending or crossed exit, deferred item, fired reopen trigger,
# and a futility or judgment summary, each with a stable first token so `next` can quote it; the
# report and exit code follow, unchanged. Exits non-zero when any ERROR-severity violation exists.
# WARNINGS print but do not fail, so this is safe as a CI gate (a broken graph fails; an advisory
# nudge does not).
# Checks: dangling edges (a target is a node ID or a repo-relative path, and either must resolve),
# unreadable edges, invalid kind/status, duplicate IDs, depends_on cycles, mutual or
# self-referencing invalidated_by/supersedes/part_of edges, transitive invalidation consistency,
# and that every `provenance:` path a node declares resolves.
set -uo pipefail
# `--explain` and `--precheck` form a leading flag block, in either order; a flag after any
# positional is a usage error (exit 2), so a misplaced flag never lints silently as if it were a
# node ID or a root. When `--explain` is among the flags, the first positional is the repo dir only
# when it is an existing directory that also looks like a root: `.`, `..`, anything with a slash in
# it, or a bare name with a graph/ inside. A bare name with neither is a node ID even when a
# directory of that name exists, so `cd repo && graph-lint.sh --explain NODE-008` renders NODE-008
# whether or not a stray NODE-008/ sits beside graph/. The remaining arguments are node IDs and the
# repo dir stays `.`. Without `--explain` the one optional positional is the repo dir, exactly as
# before, whether or not `--precheck` is given.
usage(){
  echo "usage: graph-lint.sh [--explain] [--precheck] [repo-dir] [NODE-ID ...]   (flags must come before any other argument)" >&2
  exit 2
}
EXPLAIN=0; PRECHECK=0; EXPLAIN_IDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) EXPLAIN=1; shift ;;
    --precheck) PRECHECK=1; shift ;;
    *) break ;;
  esac
done
for arg in "$@"; do
  case "$arg" in --explain|--precheck) usage ;; esac
done
if [ "$EXPLAIN" -eq 1 ]; then
  ROOT="."
  if [ $# -gt 0 ] && [ -d "$1" ]; then
    case "$1" in
      .|..|*/*) ROOT="$1"; shift ;;
      *) if [ -d "$1/graph" ]; then ROOT="$1"; shift; fi ;;
    esac
  fi
  EXPLAIN_IDS="$*"
else
  ROOT="${1:-.}"
fi

ROOT="$ROOT" EXPLAIN="$EXPLAIN" PRECHECK="$PRECHECK" EXPLAIN_IDS="$EXPLAIN_IDS" python3 <<'PY'
import os, sys, glob, re, subprocess, functools

root = os.environ.get("ROOT", ".")
graphdir = os.path.join(root, "graph")
explain = os.environ.get("EXPLAIN") == "1"
precheck = os.environ.get("PRECHECK") == "1"
explain_ids = list(dict.fromkeys(os.environ.get("EXPLAIN_IDS", "").split()))   # scope, in given order

if not os.path.isdir(graphdir):
    print("graph-lint: no graph/ directory here; repo is not scaffolded for tendrel. Nothing to lint.")
    sys.exit(0)

# Source of truth for the node model is the "Node kinds, statuses, IDs" table in
# plugin/skills/research-graph/SKILL.md. These sets mirror that table alone (session-start-report.sh
# names a few status strings inline but carries no dictionary); if the table changes, update these
# sets or the lint will reject valid nodes (or accept invalid ones). `deferred` is a choice, not a
# consequence, so it belongs to ideas and experiments only: a parked theory is `shelved`.
KINDS = {"experiment", "theory", "pipeline_node", "decision", "idea", "observation"}
STATUS = {
    "experiment":    {"planned", "running", "complete", "abandoned", "deferred"},
    "theory":        {"idea", "backtest", "paper_trade", "live_small", "live_full", "shelved"},
    "pipeline_node": {"untested", "assumed_working", "validated", "invalidated", "blocked"},
    "decision":      {"active", "under_review", "reversed"},
    "idea":          {"open", "promoted", "dropped", "deferred"},
    "observation":   set(),
}
NODE_ID = r"[A-Z]+-\d+"   # the one definition of what a node ID looks like
NODE_RE = re.compile(rf"^{NODE_ID}$")
NODE_MENTION_RE = re.compile(rf"\b{NODE_ID}\b")   # NODE_RE unanchored: IDs mentioned inside prose
FM_RE = re.compile(r"^---\n(.*?)\n---\n?(.*)$", re.S)   # frontmatter fences, then the body
EXIT_OUTCOMES = {"crossed", "overridden"}   # any other `exit_outcome` value reads as absent
# The node form of `reopen_when` is exactly `<NODE-ID> <status>` and nothing else: one ID, one
# status token. Anything that does not match is a text trigger, which is listed by the tools that
# read it and never evaluated by a script, so a sentence that happens to mention an ID is never
# mistaken for a machine-checkable trigger.
REOPEN_RE = re.compile(rf"^({NODE_ID})\s+([a-z_]+)$")

def reopen_trigger(value):
    """(node_id, status) when `value` is a node-form reopen trigger, else None for a text trigger
    or an absent key. The one evaluator both the lint and its consumers read, so "fired" means the
    same thing everywhere."""
    m = REOPEN_RE.match(value)
    return (m.group(1), m.group(2)) if m else None

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
    # might introduce: extra spaces around the colons, extra keys after `to:` (a bare target ends
    # at the first space, comma or brace, so `{rel: depends_on, to: NODE-4, weight: 1}` still
    # resolves `NODE-4`), and YAML quotes around the target. A quoted target is captured whole, so
    # `to: "docs/my plan.md"` keeps its space and `to: 'docs/a,b.md'` its comma; unquoted, the
    # same names end at the space or comma (the known limit, so quote such paths). The capture
    # keeps the quotes, and `to: "NODE-004"` is stripped to `NODE-004` here, once, before anything
    # classifies or compares it; an empty quoted target keeps its quotes so it still reads as a
    # missing path below and not as the repo root. What it deliberately does NOT accept is an edge
    # split across lines (block-style YAML); those are caught as unreadable below. Neither `.` nor
    # the quoted classes cross a newline here (no DOTALL, `\n` excluded), so each match stays
    # within one line and an unclosed quote falls back to the bare-token reading.
    edges = [(rel, to.strip('"\'') or to)
             for rel, to in re.findall(
                 r"""rel\s*:\s*([a-z_]+).*?\bto\s*:\s*("[^"\n]*"|'[^'\n]*'|[^\s},]+)""", fm)]
    id_files.setdefault(nid, []).append(name)
    # The exit-side fields (`abandon_if`, `compared_to`, `bound`, `exit_outcome`) and `reopen_when`
    # are flat optional keys read the same way as every other key: absent reads as "", so a node
    # without them behaves exactly as before. `exit_outcome` is the one value-checked key: outside
    # crossed or overridden it is stored as absent, never reported, so a typo is inert rather than
    # an error on an otherwise valid node. `next_gate` and `result` are read the same way for the
    # pre-check only; the lint itself never checks them. All of these are one-line values: a block
    # scalar (`key: |`) reads as its marker, which is empty for every purpose below.
    exit_outcome = f("exit_outcome")
    nodes[nid] = {"file": name, "fm": fm, "kind": f("kind"), "status": f("status"),
                  "body": body.strip(), "edges": edges, "provenance": provenance_paths(fm),
                  "abandon_if": f("abandon_if"), "compared_to": f("compared_to"),
                  "bound": f("bound"),
                  "exit_outcome": exit_outcome if exit_outcome in EXIT_OUTCOMES else "",
                  "reopen_when": f("reopen_when"),
                  "next_gate": f("next_gate"), "result": f("result")}

SUMMARY_WIDTH = 80

@functools.lru_cache(maxsize=None)
def edge_summary(to):
    """What --explain prints beside an edge target: the first non-blank line of the thing the edge
    points at, so a wrong target reads wrong at a glance. A node target (the quote-stripped `to`
    the loop above resolved) gives its first body line; a repo-relative file gives its first
    non-blank line after any leading frontmatter block, read with the same fence rule as a node.
    A file that opens a fence and never closes it gives the first non-blank line after the opening
    `---` instead, since a bare `---` is not a summary of anything. `(empty body)` when there is no
    such line, `(missing)` when the target is neither a node nor a
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
        elif re.match(r"^---(\n|$)", text):
            text = text[4:]     # unclosed fence: skip the opening `---` line only
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
        # Exit hygiene, warn only. A planned experiment that already carries a `config` is specified
        # well enough to pre-register the number or outcome that would end the line, so the nudge
        # lands there and nowhere else: a planned node with no config is still being shaped, and
        # nagging it would teach people to ignore the warning. A complete experiment whose
        # `validates` edge claims support for something should name the null or comparison group
        # its result beat; without `compared_to` the brief cannot tell a real gain from a rerun.
        if kind == "experiment" and status == "planned" and not rec["abandon_if"] \
                and re.search(r"^config\s*:", rec["fm"], re.M):
            warnings.append(f"{nid}: planned experiment has a config but no 'abandon_if' "
                            "(pre-register what would end this line before running it)")
        if kind == "experiment" and status == "complete" and not rec["compared_to"] \
                and any(rel == "validates" for rel, _ in rec["edges"]):
            warnings.append(f"{nid}: complete experiment validates something but names no "
                            "'compared_to' (the null or comparison group the result beat)")
    if not rec["body"]:
        warnings.append(f"{nid}: empty body (claimed but unlogged)")
    # Count how many edges the node declares (list items under `edges:`) versus how many we could
    # actually read on one line. An edge we cannot read is invisible to the dangling and
    # invalidation checks, so a broken graph could lint clean. Fail closed: report it as an error
    # in plain language, naming the file and the correct shape, rather than trusting it silently.
    if declared_edges(rec["fm"]) > len(rec["edges"]):
        errors.append(f"{nid}: couldn't read an edge in graph/{rec['file']}. "
                      "Write each edge on one line, e.g.  - {rel: depends_on, to: NODE-004}")

# reopen triggers: a node-form `reopen_when` names a node that must exist, or the trigger can never
# fire and the deferred item is parked forever behind a typo. Warn only, the same weight as the
# other hygiene nudges, and only for the node form: a text trigger is a sentence for a person to
# judge, and this lint never evaluates it, so it is never checked here either.
for nid, rec in nodes.items():
    trig = reopen_trigger(rec["reopen_when"])
    if trig and trig[0] not in nodes:
        warnings.append(f"{nid}: reopen_when names missing node {trig[0]} "
                        f"(the trigger '{rec['reopen_when']}' can never fire)")

# edge checks: dangling references and invalidation consistency. A target has exactly two readings:
# it matches the node-ID pattern and must name a node in graph/, or it is a repo-relative path
# (docs/plans/x.md, wiki/page.md, results/a.md) and must resolve the way a provenance path does,
# through the same git_status() outcomes, with one difference. A path the repo .gitignore matches is
# silent here, present or absent, where provenance warns: a link to a private plan document is
# legitimate and permanent, and a warning nobody can act on is the hygiene problem this check
# exists to remove. There is no third reading. A target that is neither a node nor a file is an
# error that names both readings, so a lowercase node-ID typo (`node-004`) fails closed instead of
# drifting past as an advisory. With no git at all, plain existence decides. A target that names a
# node FILE (`graph/NODE-003.md`) is neither reading: as a path it would resolve as a present or
# tracked file and slip past the dangling, invalidation, mutual-pair and self-loop rules, so it is
# an error that names the ID to use instead. Fail closed, never reclassify.
file_ids = {f: i for i, fs in id_files.items() for f in fs}
for nid, rec in nodes.items():
    for rel, to in rec["edges"]:
        # An existing node is a node target even when its ID strays from the PREFIX-NNN pattern;
        # the lint never validated IDs themselves, so a graph with odd IDs must not start failing
        # on every edge to them.
        norm = os.path.normpath(to)
        if NODE_RE.match(to) or to in nodes:
            if to not in nodes:
                errors.append(f"{nid}: dangling {rel} edge to missing node {to}")
        elif escapes_repo(to):
            errors.append(f"{nid}: {rel} edge target '{to}' must be repo-relative "
                          "(no absolute paths, no '..')")
        elif norm.split(os.sep)[0] == "graph" and norm.endswith(".md"):
            base = os.path.basename(norm)
            errors.append(f"{nid}: {rel} edge target {to} names a node file; "
                          f"use its ID {file_ids.get(base, base[:-3])}")
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

# precheck: the deterministic half of the `next` verdict. Enumerates, never judges: every line here
# is a fact of current frontmatter and edges (a gate names a node that is finished, a complete run
# carries an exit nobody has resolved, a deferred item's trigger names a node that holds the named
# status), so the block reads the same from any checkout of the same commit. Whether a result
# crossed its exit, or a gate that names a finished node has actually been met, is the model's call
# from the quoted lines. Rendering only, like --explain: nothing here appends to errors or warnings,
# the exit code is the lint's. Node order is file order, the same order `nodes` was built in.
TERMINAL = {"complete", "validated", "abandoned", "invalidated"}
if precheck:
    findings = []      # every line of the block, in print order; GATE_CONTEXT lines are context only
    # Reverse adjacency for part_of and motivated_by, the same shape as the depends_on `adj` below:
    # theory id -> the experiments that attach to it. Only edges FROM an experiment count; a theory
    # that points at an experiment is citing it, not being served by it.
    attached = {nid: [] for nid in nodes}
    for nid, rec in nodes.items():
        if rec["kind"] != "experiment":
            continue
        for rel, to in rec["edges"]:
            if rel in ("part_of", "motivated_by") and to in nodes:
                attached[to].append(nid)
    # Stale gate (KTD3): a substring match of node IDs inside `next_gate`, kept only when the ID is
    # a node of this graph and that node is in a terminal status. No meaning is read from the text,
    # so a gate that cites a finished run as the baseline to beat is flagged too; that shape is the
    # known false positive, pinned in the fixtures, and the brief reads the gate text to say so.
    # Shelved theories are skipped entirely: their gate is nobody's next step.
    for nid, rec in nodes.items():
        if rec["kind"] != "theory" or rec["status"] == "shelved":
            continue
        for mention in dict.fromkeys(NODE_MENTION_RE.findall(rec["next_gate"])):
            if mention in nodes and nodes[mention]["status"] in TERMINAL:
                findings.append(f"STALE_GATE {nid} {mention} {nodes[mention]['status']}")
        done = sum(1 for e in attached[nid] if nodes[e]["status"] == "complete")
        findings.append(f"GATE_CONTEXT {nid} {done} completed experiments")
    # Exits (KD9, KTD4): a complete run with an exit and no marker is pending, printed with its
    # result beside the exit so the reader (and the model) can weigh them without opening the file;
    # a crossed marker is reported as such; an overridden marker is a decline already made, so it
    # prints nothing and is never re-raised. A run that has not finished has no exit to resolve.
    for nid, rec in nodes.items():
        if rec["kind"] != "experiment" or rec["status"] != "complete":
            continue
        if rec["exit_outcome"] == "crossed":
            findings.append(f"EXIT_CROSSED {nid}")
        elif rec["abandon_if"] and not rec["exit_outcome"]:
            result = f'"{rec["result"]}"' if rec["result"] else "(no result)"
            findings.append(f'EXIT_PENDING {nid} abandon_if="{rec["abandon_if"]}" result={result}')
    # Deferred items and their triggers, evaluated by reopen_trigger() and nothing else, so "fired"
    # here is the same "fired" the session-start report prints. A missing trigger, or a node-form
    # trigger naming a node that does not exist, counts as a trigger needing judgment: a script can
    # check neither, and a typo must never pin a graph at wait.
    deferred = [(nid, rec) for nid, rec in nodes.items() if rec["status"] == "deferred"]
    judgment, fired = 0, 0
    for nid, rec in deferred:
        trig = reopen_trigger(rec["reopen_when"])
        findings.append(f"DEFERRED {nid} {rec['reopen_when'] or '(no trigger)'}")
        if trig is None or trig[0] not in nodes:
            judgment += 1
        elif nodes[trig[0]]["status"] == trig[1]:
            fired += 1
            findings.append(f"FIRED {nid} {trig[0]} {trig[1]}")
    # Futility (R3): declared only when something is deferred, nothing blocking is open, every
    # trigger is node-form, and none has fired. An open idea or a planned or running experiment
    # blocks it (there is still a next step); theories never enter the rule either way; a promoted
    # or dropped idea and a complete or abandoned run block nothing. With a text or missing trigger
    # the count of triggers needing judgment prints instead, and the verdict is the model's.
    if deferred:
        blocking = any((rec["kind"] == "idea" and rec["status"] == "open")
                       or (rec["kind"] == "experiment" and rec["status"] in ("planned", "running"))
                       for rec in nodes.values())
        if not blocking:
            if judgment:
                findings.append(f"JUDGMENT {judgment} triggers need judgment")
            elif not fired:
                findings.append(f"FUTILITY {len(deferred)} deferred, all node-form, none fired")
    print("PRECHECK:")
    for ln in findings:
        print(ln)
    if all(ln.startswith("GATE_CONTEXT ") for ln in findings):
        print("precheck: silent")
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
