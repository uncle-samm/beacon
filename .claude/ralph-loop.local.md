---
active: true
iteration: 1
session_id: 
max_iterations: 200
completion_promise: "BEACON_P4_COMPLETE"
started_at: "2026-03-16T16:15:23Z"
---

You are building Beacon, a full-stack Gleam web framework. Read docs/PROGRESS.md — milestones 57-60 fix real production bugs. 57: Targeted redirect — redirect effect must send to ONLY the triggering connection, not broadcast to all. Pass conn_id through effect context. 58: Binary-safe multipart — current parser converts to string which breaks binary files. Use binary boundary scanning. 59: Graceful shutdown — trap SIGTERM, drain WebSocket connections, configurable timeout. 60: WebSocket auth — verify session token on WS upgrade, reject unauthenticated with 401. Every [x] must have real code + tests. Verify with gleam build (zero warnings) AND gleam test (all pass). Commit and push after each milestone. Output BEACON_P4_COMPLETE only when ALL tasks in milestones 57-60 are done.
