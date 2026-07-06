# Development history: the hook-mechanism spike (2026-05)

> **Status: historical.** This documents how tendrel's core mechanism was validated before
> anything was built on it. The spike **passed** on 2026-05-29; the procedure below is
> preserved as development history, not as live instructions. The spike scripts it references
> (`plugin/scripts/stop-noop.sh`, `plugin/scripts/stop-reconcile-spike.sh`) remain in the
> repo for the same reason.

## The bet under test

Tendrel's original design hinged on one uncertain claim: that a Claude Code `Stop` hook
returning `{"decision": "block", "reason": ...}` can drive the model to actually **edit a
file** (reconcile the graph), not merely emit a response. Documentation at the time was
contradictory, so the plan gated all real construction behind an empirical spike:

- **U1 (wiring):** does a plugin-shipped Stop hook fire at all?
- **U2 (mechanism):** does the block's `reason` cause a fresh session, one with no prior
  context about the project, to open `graph/EXP-001.md` and flip its `status:` from
  `running` to `complete`?

A key methodological point: the spike had to run in a **fresh session in a scratch repo**,
because the agent that wrote the hook already knows what the hook is "supposed" to do. A
successful edit in that session would prove nothing. Attribution required a naive session
where the only reconcile prompt was the hook's `reason` (the SessionStart channel was
deliberately left unwired during the spike).

## Procedure (as run)

1. **Scratch repo:** create an empty directory with `graph/`, copy in the fixture node
   `spike-fixtures/graph/EXP-001.md` (status: `running`).
2. **Install** the plugin from the local marketplace; enable it for the scratch repo only.
3. **Run:** open a fresh session in the scratch repo, send a trivial message, let the turn
   end. The Stop hook fires; observe whether the model edits the fixture before the session
   actually stops.
4. **Read the evidence:** the hook's signal log (did `firing block` appear?) and the fixture
   file (did `status:` flip, with a reconcile note appended?).

Safety properties baked into the spike script: it only acted in a repo containing
`graph/EXP-001.md` with `status: running` (inert everywhere else, so safe to install
globally), and a per-session marker bounded it to one reconcile pass (no block loops).

## Result (2026-05-29)

**PASS.** Prompted only by the Stop hook's `reason`, the fresh session opened the fixture,
flipped `status: running -> complete`, and appended: *"Reconciled by this session on
2026-05-29: status flipped running to complete via the Stop hook."* The signal log showed one
`firing block` followed by one clean allow-exit, exactly one pass, no loop.

## What happened after

The validated per-turn Stop-hook reconcile shipped as v0.0.2 and ran in real research use,
where it surfaced a design flaw the spike couldn't: firing after *every* turn hijacked
exactly the turns where the agent had stopped to ask the user a question, burying prompts
and disrupting decisions. v0.0.3 removed the Stop hook entirely in favor of **on-demand
reconciliation** with a `SessionStart` anomaly report as the drift backstop, the model
tendrel ships with today. The mechanism remains proven and preserved here in case a future
variant (e.g. change-detection-gated reconcile) wants it back.
