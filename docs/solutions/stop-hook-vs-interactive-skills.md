---
title: A per-turn Stop hook fights interactive skills that pause to ask questions
date: 2026-07-04
type: design-learning
tags: [claude-code, hooks, plugin, interactivity, compound-engineering]
status: resolved
---

# A per-turn Stop hook hijacks question-turns

## Context

Tendrel's v0.0.2 reconciled the graph on a Claude Code `Stop` hook: the hook returned
`{"decision": "block", "reason": "reconcile the graph"}` after every turn, which reliably drove
the model to fold the session's work into `graph/`. The mechanism itself was sound and had been
validated in a fresh-session spike (see [`../history/SPIKE.md`](../history/SPIKE.md)). The hook
did force the write.

## The problem

A `Stop` hook fires on **every** stop, including the turns where the agent has deliberately
stopped to ask *you* a question. In real research use, running alongside compound-engineering
(whose brainstorm / plan / work skills pause constantly for `AskUserQuestion` decisions), the
reconcile `reason` fired on exactly those question-turns. It buried the pending question under
reconcile output and disrupted the decision the user was in the middle of making. A hook that was
correct in isolation became wrong the moment any interactive skill shared the session.

## The fix

v0.0.3 removed the `Stop` hook entirely. Reconciliation became **on-demand**
(`/tendrel:reconcile` or *"reconcile the graph"*), with a read-only `SessionStart` anomaly report
as the drift backstop. The only automatic behavior left never blocks and never interrupts.

## The generalizable lesson

A `Stop` hook cannot distinguish "the agent finished the work" from "the agent paused to ask you
something." Both look identical at the turn boundary. So driving an *action* from `Stop` is only
safe for behavior that should happen unconditionally at every turn. Anything the user should
**pace**, or anything that must not collide with another plugin's interactive turns, belongs
on-demand (a slash command or natural language), with `SessionStart` limited to read-only
reporting.

This is a direct **compatibility constraint**, not just an ergonomics preference: for a plugin to
coexist with interactive workflow plugins like compound-engineering, it must not drive writes from
`Stop`. Tendrel's current shape (one read-only `SessionStart` hook, everything else on-demand,
inert outside `graph/` repos) is what makes that coexistence hold.
