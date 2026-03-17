# TigerStyle Coding Principles

> Adapted from [TigerBeetle's TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) for the Beacon framework. TigerStyle is the coding methodology used by the TigerBeetle database team — we adopt its principles because building a web framework has the same requirement: if something goes wrong, you need to know immediately, not three hours later from a user report.

## Core Philosophy

**The cost of a crash is low. The cost of silent corruption is unbounded.**

A process that crashes with a clear assertion message is easy to fix: you see the error, you find the line, you understand the invariant that was violated. A process that silently swallows an error and continues with bad state can corrupt data, confuse users, and take hours to diagnose.

## The Principles

### 1. No Error Swallowing

Every error must be explicitly handled or propagated. Never write:

```gleam
// BAD — error is invisible
case do_thing() {
  Ok(value) -> use(value)
  Error(_) -> Nil
}

// GOOD — error is visible
case do_thing() {
  Ok(value) -> use(value)
  Error(err) -> {
    log.warning("module", "do_thing failed: " <> string.inspect(err))
    Nil
  }
}
```

If you catch yourself writing `Error(_) -> Nil`, stop. Either:
- Log the error with context (module, function, what failed, why it matters)
- Propagate it via `Result` to the caller
- Assert it can't happen with `let assert Ok(value) = ...` and document why

### 2. Log Everything

All significant state transitions, errors, warnings, and decisions must be logged with structured context.

```gleam
// Levels:
log.error("module", "msg")    // Failures that need attention
log.warning("module", "msg")  // Unexpected but handled
log.info("module", "msg")     // State transitions (connected, disconnected, started)
log.debug("module", "msg")    // Detailed tracing (every event, every render)
```

Rules:
- Every public function in transport, runtime, and store modules should log at appropriate levels
- Error paths must ALWAYS log — an error that isn't logged doesn't exist
- Include enough context to diagnose without a debugger: IDs, counts, reasons
- Use debug level for high-frequency operations (store.get, every mousemove) to avoid spam

### 3. Assert Invariants Aggressively

If something "can't happen," assert it. When it does happen, you'll know immediately.

```gleam
// Document WHY the assertion is safe
// INVARIANT: The listener process was just spawned and MUST send its
// command_subject within 5 seconds. Timeout = fatal configuration error.
let assert Ok(command_subject) = process.receive(reply_subject, 5000)
```

Rules:
- Every `let assert` must have a comment explaining the invariant
- Use `let assert` only when the invariant is truly guaranteed by program logic
- For runtime validation (user input, network data), use `Result` instead
- Never use `todo` or `panic` in shipped code

### 4. Crash Early, Crash Loudly

A crash with a clear message is better than silent corruption:

```gleam
// BAD — continues with potentially corrupt state
case validate(input) {
  Ok(valid) -> process(valid)
  Error(_) -> process(default_value)  // What if default is wrong?
}

// GOOD — caller knows immediately
case validate(input) {
  Ok(valid) -> process(valid)
  Error(err) -> Error(err)  // Propagate — let the caller decide
}
```

On the BEAM, crashes are cheap. Supervisors restart processes. A crashed process with a clear error in the logs is infinitely preferable to a running process with corrupt state.

### 5. Error Types Carry Context

Error messages must contain enough information to diagnose the failure:

```gleam
// BAD
Error("Failed to save file")

// GOOD
Error("Failed to save " <> path <> ": " <> string.inspect(os_error))
```

Custom error types should carry structured context:

```gleam
pub type BeaconError {
  TransportError(reason: String)
  CodecError(reason: String, raw: String)
  RuntimeError(reason: String)
}
```

### 6. No Shortcuts

- No "quick fixes" that paper over the real problem
- No `todo` or `panic` in shipped code
- No "temporary" hacks — they become permanent
- If a fix feels hacky, step back and find the proper solution
- Stability and correctness over velocity

### 7. Test the Unhappy Paths

Test what happens when things go wrong, not just when they go right:

- What happens when a WebSocket disconnects mid-event?
- What happens when the client sends binary garbage?
- What happens when 1000 connections hit the server simultaneously?
- What happens when a process crashes during an update?

Our simulation testing framework (`test/beacon/sim/`) exercises these scenarios:
- **1000 concurrent connections** — all succeed, zero process leak
- **Corrupt data** — partial JSON, binary noise, 10KB payloads, invalid handlers — server survives with zero process leak
- **Rapid event flooding** — 500 events on a single connection
- **Memory leak detection** — connect/disconnect 100 times, measure delta

### 8. Zero Tolerance for Leaks

If a test measures 0 leaked processes, assert exactly 0 — not "less than 10." If it ever leaks 1 process, that's a bug, and we want to know immediately:

```gleam
// BAD — tolerates up to 9 leaked processes
let assert True = processes_leaked < 10

// GOOD — zero means zero
let assert True = processes_leaked == 0
```

## How We Enforce This

1. **Custom linter** (`src/beacon/lint.gleam`) — scans AST for banned patterns
2. **Simulation tests** (`test/beacon/sim/`) — real connections, fault injection, leak detection
3. **Code review** — every `Error(_) -> Nil` is a red flag
4. **CI** — `gleam build` (zero warnings) + `gleam test` (all pass) + linter (zero violations)
