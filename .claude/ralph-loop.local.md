---
active: true
iteration: 1
session_id: 
max_iterations: 200
completion_promise: "BEACON_PERF_COMPLETE"
started_at: "2026-03-17T08:31:48Z"
---

You are optimizing rendering performance for Beacon, a full-stack Gleam web framework. Read docs/PROGRESS.md Milestone 61 for the full task list. CRITICAL BOTTLENECK: every LOCAL mousemove event re-renders ALL SVG strokes client-side (500 strokes x 60fps = 30K element renders/sec). The BEAM server side is fine — this is a client-side rendering problem in beacon_client_ffi.mjs. TASKS: (1) Add requestAnimationFrame throttling to clientRender — batch LOCAL events into one render per frame. (2) Skip full view_to_html + morphInnerHTML for LOCAL events that only append children — append new SVG line directly. (3) Benchmark with 100/500/1000 strokes to measure improvements. (4) Coalesce consecutive same-handler LOCAL events in the buffer. (5) Optimize server patches — SVG attributes should be dynamic not static. Key files: beacon_client/src/beacon_client_ffi.mjs (clientRender, morphInnerHTML, handleEventLocally), src/beacon/view.gleam, src/beacon/template/rendered.gleam, examples/src/canvas.gleam. Verify with gleam build (zero warnings) AND gleam test (all pass). Commit and push after each optimization. Output BEACON_PERF_COMPLETE only when canvas drawing is smooth at 500+ strokes.
