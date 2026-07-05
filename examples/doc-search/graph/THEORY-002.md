---
id: THEORY-002
kind: theory
status: idea
confidence: moderate
next_gate: "reranker recovers >=80% of precision lost to chunking on 50 queries"
edges:
  - {rel: part_of, to: EXP-003}
---
A cross-encoder reranker recovers most of the precision lost to naive chunking.
