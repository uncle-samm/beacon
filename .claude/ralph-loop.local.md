---
active: true
iteration: 1
session_id: 
max_iterations: 0
completion_promise: null
started_at: "2026-03-16T12:41:00Z"
---

You are building Beacon, a full-stack Gleam web framework. Read docs/PROGRESS.md — milestones 39-42 are P0 (core architecture gaps). Start with milestone 39 (Model Sync): when client sends a model-affecting event, server must send back authoritative Model so client/server stay in sync. Generate JSON codecs for user's Model type in the build tool, wire model_sync message through transport, client receives and replaces its Model. Then milestone 40 (Error Recovery), 41 (Routing), 42 (Server Functions). Every [x] must have real code + tests. Verify with gleam build (zero warnings) AND gleam test (all pass). Commit and push after each milestone. Do NOT mark done until feature works end-to-end. Output BEACON_COMPLETE only when ALL tasks in milestones 39-42 are checked off with real implementations.
