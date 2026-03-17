---
name: tigerstyle
description: Run a TigerStyle compliance audit on the Beacon codebase. Finds error swallowing, missing logging, undocumented assertions, and banned patterns.
---

# TigerStyle Compliance Audit

You are auditing the Beacon codebase against TigerStyle coding principles (see docs/TIGERSTYLE.md for the full reference).

## Scope

Audit `$ARGUMENTS` (or all of `src/beacon/` if no path given).

## Checks to Run

### 1. Error Swallowing (CRITICAL)

Search for these patterns — every one is a violation:

- `Error(_) -> Nil` — error silently discarded
- `Error(_) -> []` — error masked as empty list
- `Error(_) -> Error(Nil)` — error context lost (original reason dropped)
- `Error(_) -> default_value` without logging — silent fallback
- `_ ->` catch-all in case expressions that could match errors

For each match, check: is there a `log.warning` or `log.error` call? If not, it's a violation.

### 2. Missing Logging

Check all public functions (`pub fn`) in these critical modules:
- `src/beacon/runtime.gleam`
- `src/beacon/transport.gleam`
- `src/beacon/pubsub.gleam`
- `src/beacon/store.gleam`
- `src/beacon/state_manager.gleam`
- `src/beacon/session.gleam`

Each public function should have at least one `log.*` call (info, debug, warning, or error).

### 3. Undocumented Assertions

Find all `let assert` usages. Each MUST have a comment above it explaining:
- What invariant is being asserted
- Why it's guaranteed to hold

### 4. Banned Patterns

- `todo` in shipped code (src/, not test/)
- `panic` in shipped code
- Generic error messages without context (e.g., `"failed"` without saying what failed)

### 5. Simulation Test Coverage

Verify that `gleam test` passes and check the simulation test results:
- Run `gleam test` and report pass/fail count
- Check if any sim tests have loose thresholds (process leak > 0 allowed where it shouldn't be)

## Output Format

For each violation:
```
[SEVERITY] file:line — pattern_type
  Code: <the offending line>
  Fix: <what to change>
```

Severities: CRITICAL (error swallowing), HIGH (missing logging), MEDIUM (undocumented assert), LOW (generic message)

End with a summary:
```
TigerStyle Audit Results:
  CRITICAL: N
  HIGH: N
  MEDIUM: N
  LOW: N
  Status: PASS / FAIL (FAIL if any CRITICAL)
```

If the codebase is clean, celebrate it. If not, offer to fix the violations.
