---
active: true
iteration: 1
session_id: 
max_iterations: 200
completion_promise: "CDP_VERIFICATION_COMPLETE"
started_at: "2026-03-17T15:09:16Z"
---

You are verifying every Beacon example via CDP (Chrome DevTools Protocol) with full monitoring. Read docs/PROGRESS.md Milestone 64 for the task list. FOR EACH EXAMPLE: (1) Kill any running server, start the example on port 8080. (2) Navigate Chrome tab to http://localhost:8080/. (3) Install full monitoring: DOM mutations, console errors, WS traffic. (4) Interact with the app through CDP — type inputs, click buttons, verify responses. (5) Check: zero console errors, DOM updates match expectations, WS messages valid. (6) If ANY bug found: investigate immediately, fix the code, rebuild, retest. (7) Check off the task in PROGRESS.md, commit+push, move to next example. ORDER: Snake (64.1) → Dashboard (64.2) → Kanban (64.3) → Chat (64.4) → Canvas (64.5). Use a single Python script per test for atomicity. Chrome tabs: TAB1=EE4DAEC57906697399A8A8687289D094 TAB2=D8802BB11FCD20FF2BF7D26BAE86CC4E. Output CDP_VERIFICATION_COMPLETE only when ALL 64.x tasks are checked off.
