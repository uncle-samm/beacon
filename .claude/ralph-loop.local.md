---
active: true
iteration: 2
session_id: 
max_iterations: 200
completion_promise: "SIM_TESTING_COMPLETE"
started_at: "2026-03-17T09:49:36Z"
---

You are implementing TigerBeetle compliance fixes and a full-system simulation testing framework for Beacon, a full-stack Gleam web framework. Read docs/PROGRESS.md Milestone 62 for the full task list. Read the plan at .claude/plans/bubbly-squishing-naur.md for detailed implementation guidance. IMPLEMENTATION ORDER: (1) Fix all TigerBeetle violations first (62.1a-h) — these hide bugs that simulation tests would find. (2) Build metrics layer (62.2). (3) Scenario engine (62.3). (4) Test app helper + connection pool (62.4). (5) Reporter + scale tests (62.5). (6) Fault injection (62.6). CRITICAL RULES: Always verify with gleam build (zero warnings) AND gleam test (all pass) after each change. Commit and push after each sub-milestone. Use existing patterns from test/beacon/integration_test.gleam (WS client via beacon_http_client_ffi.erl, dynamic ports, concurrent spawning). Use existing beacon/debug.gleam for metrics. Output SIM_TESTING_COMPLETE only when ALL tasks in Milestone 62 are checked off AND all simulation tests pass.
