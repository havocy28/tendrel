#!/usr/bin/env bash
# U5 — SessionStart report. Emits hookSpecificOutput.additionalContext with an anomaly-LED
# summary so drift is loud at session open (R1/AE1), plus a conservative edge-symmetry audit
# (R15/AE4 Stage-1 trigger candidate). Inert (says nothing) in repos without a graph/ dir.
# v0.0.3: reconciliation is on-demand (this report nudges); the per-turn Stop block was removed.
# v0.4.0: honors optional `verbosity` (succinct | normal | off) from .research-graph; absent -> normal.
set -euo pipefail
DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.research-graph-data}"
payload="$(cat || true)"

DATA="$DATA" PAYLOAD="$payload" python3 <<'PY'
import os, sys, json, glob, re

data = os.environ.get("DATA", "")
payload = os.environ.get("PAYLOAD", "") or "{}"
try:
    cwd = json.loads(payload).get("cwd", "") or os.getcwd()
except Exception:
    cwd = os.getcwd()

graphdir = os.path.join(cwd, "graph")

def emit(ctx):
    if ctx:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                                  "additionalContext": ctx}}))
    sys.exit(0)

if not os.path.isdir(graphdir):
    emit("")  # not a research repo -> say nothing

nodes = {}
for path in sorted(glob.glob(os.path.join(graphdir, "*.md"))):
    text = open(path, encoding="utf-8", errors="replace").read()
    m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.S)
    fm, body = (m.group(1), m.group(2)) if m else (text, "")
    def f(key):
        mm = re.search(rf"^{key}:\s*(.+)$", fm, re.M)
        return mm.group(1).strip().strip('"') if mm else ""
    nid = f("id") or os.path.basename(path)[:-3]
    edges = re.findall(r"rel:\s*([a-z_]+),\s*to:\s*([^\s}]+)", fm)
    nodes[nid] = {"kind": f("kind"), "status": f("status"),
                  "body": body.strip(), "edges": edges}

empty_body    = sorted(n for n, v in nodes.items() if not v["body"])
open_theories = sorted((n, v["status"]) for n, v in nodes.items()
                       if v["kind"] == "theory" and v["status"] != "shelved")
weak_nodes    = sorted((n, v["status"]) for n, v in nodes.items()
                       if v["kind"] == "pipeline_node"
                       and v["status"] in ("untested", "assumed_working", "invalidated", "blocked"))
dangling = []
for n, v in nodes.items():
    for rel, to in v["edges"]:
        if rel == "depends_on" and re.match(r"^[A-Z]+-\d+$", to) and to not in nodes:
            dangling.append((n, to))

# Optional verbosity from .research-graph (key = value; additive, absent/unknown -> normal).
# .research-graph is key=value (NOT colon frontmatter); tolerate whitespace and # comments.
verbosity = "normal"
try:
    for line in open(os.path.join(cwd, ".research-graph"), encoding="utf-8-sig", errors="replace"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, val = line.partition("=")
        if k.strip() == "verbosity":
            raw = val.split("#", 1)[0].strip().strip('"').lower()   # tolerate a trailing # comment
            if raw in ("succinct", "normal", "off"):
                verbosity = raw
except OSError:
    pass

header = f"Research graph for this project: {len(nodes)} node(s)."
# Confidently-wrong anomalies (high severity): the set that breaks silence even under 'off'.
warn_lines = []
if empty_body:
    warn_lines.append(f"WARN {len(empty_body)} node(s) with EMPTY body (claimed but unlogged): {', '.join(empty_body)}")
if dangling:
    warn_lines.append("WARN depends_on -> missing node (Stage-1 trigger candidate; log to FRICTION): "
                      + "; ".join(f"{a}->{b}" for a, b in dangling))
info_lines = []
if open_theories:
    info_lines.append("Open theories: " + ", ".join(f"{n} ({s})" for n, s in open_theories))
if weak_nodes:
    info_lines.append("Unvalidated/blocked pipeline nodes: " + ", ".join(f"{n} ({s})" for n, s in weak_nodes))
footer = ("Reconcile on demand: say \"reconcile the graph\" to fold recent work into graph/ "
          "per the research-graph skill. (Reconciliation is no longer auto-fired every turn — "
          "it will not interrupt you mid-task.)")

if verbosity == "off":
    # Silent except confidently-wrong anomalies: the report is the sole automatic drift signal
    # since the Stop hook was removed in 0.0.3.
    emit("\n".join(warn_lines))
elif verbosity == "succinct":
    emit("\n".join([header] + warn_lines + info_lines))
else:  # normal, and any absent or unknown value: byte-identical to pre-0.4.0 output
    emit("\n".join([header] + warn_lines + info_lines + [footer]))
PY
