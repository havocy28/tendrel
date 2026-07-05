---
id: THEORY-001
kind: theory
status: backtest
confidence: high
next_gate: "hybrid > vector-only by >5 pts nDCG on the held-out set -> paper_trade"
edges:
  - {rel: part_of, to: EXP-001}
  - {rel: part_of, to: EXP-002}
---
Hybrid keyword+vector retrieval beats vector-only on our eval set.
