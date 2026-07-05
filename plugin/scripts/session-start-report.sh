#!/usr/bin/env bash
# U5 — SessionStart report. Emits hookSpecificOutput.additionalContext with an anomaly-LED
# summary so drift is loud at session open (R1/AE1), plus a conservative edge-symmetry audit
# (R15/AE4 Stage-1 trigger candidate). Inert (says nothing) in repos without a graph/ dir.
# v0.0.3: reconciliation is on-demand (this report nudges); the per-turn Stop block was removed.
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

out = [f"Research graph for this project: {len(nodes)} node(s)."]
if empty_body:
    out.append(f"WARN {len(empty_body)} node(s) with EMPTY body (claimed but unlogged): {', '.join(empty_body)}")
if dangling:
    out.append("WARN depends_on -> missing node (Stage-1 trigger candidate; log to FRICTION): "
               + "; ".join(f"{a}->{b}" for a, b in dangling))
if open_theories:
    out.append("Open theories: " + ", ".join(f"{n} ({s})" for n, s in open_theories))
if weak_nodes:
    out.append("Unvalidated/blocked pipeline nodes: " + ", ".join(f"{n} ({s})" for n, s in weak_nodes))
out.append("Reconcile on demand: say \"reconcile the graph\" to fold recent work into graph/ "
           "per the research-graph skill. (Reconciliation is no longer auto-fired every turn — "
           "it will not interrupt you mid-task.)")
emit("\n".join(out))
PY
