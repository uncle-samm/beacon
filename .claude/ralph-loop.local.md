---
active: true
iteration: 1
session_id: 
max_iterations: 200
completion_promise: "BEACON_COMPLETE"
started_at: "2026-03-16T08:53:19Z"
---

You are building Beacon, a full-stack Gleam web framework. Read docs/PROGRESS.md and .claude/plans/bubbly-squishing-naur.md for full context. Milestones 29-35 add CLIENT-SIDE update execution. The user writes one Model (server shared) and one Local (client instant). The update function runs on BOTH sides — compiled to JS via build tool. Auto-inference: if only Local changed, zero server traffic. If Model changed, sync with server. Milestone 29: remove Erlang FFI from pure modules (element, view, rendered). Milestone 30: app_with_local API + runtime support. Milestone 31: build tool (Glance analyze, codegen, compile to JS). Milestone 32: JS handler registry. Milestone 33: client MVU runtime. Milestone 34: server sync protocol. Milestone 35: integration + rewrite examples. gleam build zero warnings, gleam test all pass, existing tests must not break. Output BEACON_COMPLETE when all 7 milestones done.
