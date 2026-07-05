# doc-search — status

*Generated on demand from `graph/` by tendrel. Do not hand-edit — regenerate with
`/tendrel:status` (or "regenerate status.md").*

## Graph

```mermaid
flowchart TB
  THEORY001(["THEORY-001<br/>hybrid > vector-only<br/>(backtest)"])
  THEORY002(["THEORY-002<br/>reranker recovers precision<br/>(idea)"])
  EXP001["EXP-001<br/>vector-only baseline"]
  EXP002["EXP-002<br/>hybrid retrieval"]
  EXP003["EXP-003<br/>reranker eval (running)"]
  NODE001["NODE-001<br/>ingestion + chunking"]
  NODE002["NODE-002<br/>embedding index"]
  NODE003["NODE-003<br/>vector-only retriever"]
  NODE004["NODE-004<br/>end-to-end answer quality"]
  DEC001["DEC-001<br/>512-token chunks"]
  IDEA001["IDEA-001<br/>query expansion"]
  OBS001["OBS-001<br/>recall drops on tables"]

  EXP001 -->|part_of| THEORY001
  EXP002 -->|part_of| THEORY001
  EXP002 -->|validates| THEORY001
  EXP002 -->|invalidated_by| NODE003
  EXP003 -->|part_of| THEORY002
  EXP003 -->|spawned| IDEA001
  NODE002 -->|depends_on| NODE001
  NODE003 -->|depends_on| NODE002
  NODE004 -->|depends_on| NODE003
  NODE001 -->|part_of| DEC001
  DEC001 -->|motivated_by| OBS001
  IDEA001 -->|motivated_by| OBS001

  classDef validated fill:#e6f4ea,stroke:#137333;
  classDef invalidated fill:#fce8e6,stroke:#c5221f,color:#611;
  classDef blocked fill:#fef7e0,stroke:#e37400,stroke-dasharray:4 3;
  class NODE001,NODE002 validated;
  class NODE003 invalidated;
  class NODE004 blocked;
```

> Legend: green = validated · red = invalidated · orange/dashed = blocked · stadium = theory (with lifecycle stage).

## Theories

- **THEORY-001** — hybrid keyword+vector beats vector-only. `backtest`, confidence **high**.
  Next gate: hybrid > vector-only by >5 pts nDCG → `paper_trade`. Supported by EXP-002.
- **THEORY-002** — a reranker recovers precision lost to chunking. `idea`, confidence moderate.
  Next gate: reranker recovers ≥80% of lost precision on 50 queries. Being tested by EXP-003.

## Pipeline nodes by evidence status

- **validated:** NODE-001 (ingestion + chunking), NODE-002 (embedding index)
- **invalidated:** NODE-003 (vector-only retriever — beaten by hybrid in EXP-002; being replaced)
- **blocked:** NODE-004 (end-to-end answer quality — waiting on the retriever replacement)

## Decisions

- **DEC-001** (active) — 512-token chunks, 64-token overlap. Best recall/latency trade-off.

## Open ideas

- **IDEA-001** — query expansion for table/figure queries (motivated by OBS-001).
