---
active: true
iteration: 2
session_id: 
max_iterations: 50
completion_promise: "ALL_TESTS_HARDENED_AND_PASSING"
started_at: "2026-03-18T23:37:26Z"
---

Comprehensive test hardening for Beacon's JSON patch state sync and simulation infrastructure. This is a multi-part task — do ALL of it, verify everything compiles and passes. Do NOT output the completion promise until gleam build has zero warnings, gleam test passes ALL tests (old + new), and python3 test_all_cdp.py passes all CDP tests. If something fails, fix it and keep iterating.

## Part 1: Patch Optimization Tests (runtime_test.gleam + patch_test.gleam)

Add tests that PROVE the optimization works:

1. **Assert SendPatch not SendModelSync** — After initial join (which sends model_sync), subsequent events MUST produce SendPatch. Add a test: connect, join, drain mount+model_sync, send increment, assert the response is SendPatch (not SendModelSync). This catches regressions where we silently fall back to full sync.

2. **Patch size < model size** — After 50 increments, the patch for increment 51 should be tiny (just /count replace). Add a test that measures string length of the ops_json and asserts it's < 50 bytes while the full model_sync would be larger.

3. **Append detection for arrays** — Test that appending to an array produces an append op (not replace). Use patch.diff with old={items:[1,2,3]} new={items:[1,2,3,4,5]} and assert the ops contain append. Then test that modifying an element produces replace.

4. **Client ops path** — Add a runtime test that sends an event WITH ops (simulating client-side diff). Verify the server applies the ops and the resulting model is correct. This is the canvas/kanban code path.

5. **Roundtrip fidelity** — For 10 different model shapes (nested objects, arrays of objects, mixed types), diff then apply and assert the result equals the original new model exactly.

## Part 2: Simulation Infrastructure Upgrades (sim/ modules)

Upgrade the sim infrastructure to track wire efficiency and validate responses:

### 2a. Metrics additions (metrics.gleam)
- Add bytes_sent and bytes_received counters
- Add patches_received and model_syncs_received counters
- Add mount_received counter
- Update collect/SimMetrics to include these

### 2b. Scenario additions (scenario.gleam)
- Add WaitForPatch(timeout_ms) action — waits for response, asserts it is type patch
- Add WaitForModelSync(timeout_ms) action — waits for response, asserts it is type model_sync
- Add AssertResponseContains(timeout_ms, expected) — waits for response, asserts content contains expected string
- Add WaitForAnyResponse(timeout_ms) action — like current WaitForResponse but tracks message type in metrics

### 2c. Pool updates (pool.gleam)
- Track bytes on ws_send and ws_recv
- Parse response type (patch/model_sync/mount/heartbeat_ack) and increment appropriate counter
- Update WaitForResponse to use new WaitForAnyResponse behavior

### 2d. Report updates (report.gleam)
- Add bytes_sent, bytes_received, patches_received, model_syncs_received to SimReport
- Log wire efficiency stats
- Add assert: if patches_received > 0, assert patches_received > model_syncs_received (optimization is working)

## Part 3: New Simulation Scenarios

### 3a. State correctness test
New scenario: send 50 increments, then WaitForAnyResponse, assert the response contains count 50. Proves the server actually processed all events correctly.

### 3b. Patch efficiency test
New scenario: connect, join (gets model_sync), send 10 increments each with WaitForAnyResponse. Assert: got 1 model_sync (initial) + 10 patches (increments). Assert: total patch bytes < total model_sync bytes would have been.

### 3c. Reconnection test
New scenario: connect, join, send 5 increments, disconnect, reconnect, join again. Assert the model_sync on rejoin shows count >= 5 (state preserved).

### 3d. Concurrent mutation test
New test: 10 connections to same shared counter, each sends 10 increments. After all done, open new connection — model_sync should show count close to 100.

### 3e. Server-push test (effect.every pattern)
Create a test app with effect.every(100ms, Tick) that increments a counter. Connect, join, sleep 1s, check that multiple patches arrived with incrementing tick counts.

## Part 4: Verify Everything

1. gleam build — zero warnings
2. gleam test — all pass (existing 485 + new tests)
3. python3 test_all_cdp.py — all CDP tests pass (no regression)

Read docs/PROGRESS.md first. Update it when done.
