---
active: true
iteration: 1
session_id: 
max_iterations: 200
completion_promise: "STRESS_EXAMPLES_COMPLETE"
started_at: "2026-03-17T14:30:48Z"
---

You are building server-push primitives and stress-testing examples for Beacon, a full-stack Gleam web framework. Read docs/PROGRESS.md Milestone 63 for the full task list. IMPLEMENTATION ORDER: (1) 63.1 Server-push primitive — add effect.every() and effect.after() to the framework. The runtime needs a timer loop using process.send_after that dispatches tick messages. This is the foundation — Snake and Dashboard both need it. (2) 63.2 Multiplayer Snake — game loop via effect.every(150, Tick), arrow keys, shared store, collision detection. (3) 63.3 Live Dashboard — server pushes beacon/debug.stats() every second, renders process count + memory + uptime. (4) 63.4 Kanban Board — drag-and-drop with on_dragstart/on_dragover/on_drop, shared store, concurrent edits. (5) 63.5 Presence-Aware Chat — enhance existing chat with who-is-online and typing indicators. KEY FILES: src/beacon/effect.gleam (add every/after), src/beacon/runtime.gleam (handle timer messages), src/beacon/examples/ (all examples live here or in examples/src/). RULES: gleam build zero warnings, gleam test all pass, commit+push after each sub-milestone. Reference Phoenix LiveView handle_info + Process.send_after for timer pattern. Output STRESS_EXAMPLES_COMPLETE only when ALL 63.x tasks are checked off.
