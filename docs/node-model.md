# Node model reference

The `research-graph` skill (`plugin/skills/research-graph/SKILL.md`) is the source of truth; this
doc is the reference view of it. If the two ever disagree, the skill wins.

## Node file shape

One file per node, `graph/<ID>.md`: YAML frontmatter plus a lab-notebook body.

```markdown
---
id: EXP-012
kind: experiment
status: complete
question: "Does Sonnet zero-shot match PetBERT on disease NER?"
config: {model: sonnet, dataset: peteval-ner, n: 500}
result: "F1 0.87 vs PetBERT 0.84"
edges:
  - {rel: part_of, to: THEORY-002}
  - {rel: validates, to: DEC-003}
---
Ran with the v2 prompt. 3 misses traced to Australian drug abbreviations, see OBS-004.
```

**Frontmatter stays flat:** one field per line, no multi-line or nested YAML values. The
inline-map (`config: {...}`) and inline-list (`edges:`) forms above are fine; don't break them
across lines. Flat frontmatter is what lets the report/status scripts parse it reliably.

## Kinds, statuses, IDs

| Kind | ID prefix | What it is | `status` vocabulary |
|---|---|---|---|
| `experiment` | `EXP-` | A concrete thing you ran, with a question and a result | planned · running · complete · abandoned |
| `theory` | `THEORY-` | A hypothesis container with a lifecycle | idea · backtest · paper_trade · live_small · live_full · shelved |
| `pipeline_node` | `NODE-` | A system component whose correctness is open | untested · assumed_working · validated · invalidated · blocked |
| `decision` | `DEC-` | A methodological choice, with its evidence | active · under_review · reversed |
| `idea` | `IDEA-` | Something to maybe try later | open · promoted · dropped |
| `observation` | `OBS-` | A pattern/anomaly noticed; no lifecycle | (none) |

Per-kind attributes (expected, not enforced): `experiment` needs `question`, `config`; `theory`
needs `confidence` (low/moderate/high), `next_gate`; `pipeline_node` takes an optional `eval`.

**IDs** are human-readable, zero-padded, per-(project, kind): `EXP-001`, `THEORY-001`. Reference
them by ID in conversation ("blocked on `NODE-003`") so the graph stays legible.

## Edge relations

Directed. `relation` is an extensible string; the recommended set:

| Relation | Reads as | Use |
|---|---|---|
| `depends_on` | A depends_on B | A can't proceed/be trusted until B is done/validated. Also models "blocked by." |
| `validates` | A validates B | A is evidence supporting B. |
| `invalidated_by` | A invalidated_by B | Evidence B undermines A. |
| `supersedes` | A supersedes B | A replaces B; treat B as historical. |
| `part_of` | A part_of B | A belongs to container B (experiment into theory). |
| `motivated_by` | A motivated_by B | B (observation/result/wiki page) is why A exists. |
| `spawned` | A spawned B | Working on A produced B. |

An edge `to:` target may be a node ID **or** a `wiki/` path. That's the cross-layer link. The
graph stores the link; the content stays in the wiki file.

## The pipeline DAG

A pipeline isn't a separate kind. It's the DAG that `depends_on` edges form among
`pipeline_node`s. When one is set to `invalidated`, everything downstream (via incoming
`depends_on` edges) is what a reconcile traces and reports as now-untrustworthy or `blocked`.
