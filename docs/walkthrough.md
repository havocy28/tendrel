# Walkthrough: tendrel on the doc-search example

The fastest way to see tendrel work end to end. It uses the sanitized example graph shipped in
[`../examples/doc-search`](../examples/doc-search) (12 nodes about a made-up document-search
project), so nothing here touches your real work. Every command is real and every output renders
in your terminal or on GitHub.

## 1. Get the example

If you cloned this repo it's already here:

```bash
cd examples/doc-search
```

The folder is a complete tendrel project: a `graph/` of 12 typed nodes, empty `raw/` and `wiki/`
folders, and a `.research-graph` marker. That `graph/` directory is what turns the plugin on for
the repo.

## 2. Open a session and read the report

Install and enable the plugin (see the README's Install section), then open a Claude Code session
from this folder:

```bash
cd examples/doc-search && claude
```

At session start the `SessionStart` hook injects the report into the agent's context. It is not a
printed banner; it shapes the agent's first answer. Ask:

> From the research graph, what's the current state and what should I look at first?

The agent answers from the graph: 12 nodes, two open theories (THEORY-001 at backtest, THEORY-002
still an idea), NODE-003 invalidated, and NODE-004 blocked downstream of it. It will point you at
the critical path: replace the invalidated retriever, which unblocks end-to-end evaluation.

## 3. See the graph

Regenerate the visual view:

> /tendrel:status

This writes `status.md`: a mermaid diagram of the actual graph (invalidated and blocked nodes
highlighted) plus grouped text sections. On GitHub the diagram renders inline; in your editor use
any mermaid preview. The committed
[`examples/doc-search/status.md`](../examples/doc-search/status.md) is a rendered example you can
browse right now.

## 4. Finish an experiment and reconcile

The graph reflects work in progress: EXP-003 (reranker eval) is `running`, and THEORY-002 is gated
on it. Tell the agent what happened, then reconcile:

> EXP-003 finished. The cross-encoder reranker recovered 85% of the precision lost to chunking.
> Reconcile the graph.

Reconcile folds the result into `graph/`: EXP-003 moves `running` to `complete` with its result
recorded, and THEORY-002 advances toward `backtest` because its gate (recover at least 80% of the
lost precision) is now met. Check the files:

```bash
cat graph/EXP-003.md graph/THEORY-002.md
```

## 5. Trace an invalidation

The real power shows when a result breaks something downstream. Try:

> The hybrid retriever that replaced NODE-003 fails on table queries. Mark it invalidated and tell
> me what's affected.

Tendrel sets the node to `invalidated` and traces every node whose edges point at it, reporting
what is now blocked or untrustworthy. That is the "what falls when it doesn't hold" behavior, done
for you in one step instead of held in your head.

## Reset

The reconcile edits example files in your clone. To restore them:

```bash
git checkout examples/doc-search
```

That is the loop: open, read the report, work, reconcile at a pause, and check status when you
want the map. Nothing forces reconciliation; the SessionStart report is the backstop that tells
you when the graph has fallen behind.
