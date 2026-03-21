# Beacon

Full-stack Gleam web framework on BEAM. MVU architecture, one process per session, WebSocket transport.

## Learn More

| File | What you'll learn |
|------|-------------------|
| `docs/ARCHITECTURE.md` | Technical architecture, all modules, wire protocol, deps, project structure |
| `docs/GETTING_STARTED.md` | Quick start, builder API, three state layers, routing |
| `docs/PROGRESS.md` | **Current milestone + completed work — read FIRST every session** |
| `docs/TIGERSTYLE.md` | Full TigerStyle engineering principles |
| `docs/SECURITY.md` | SecurityLimits, origin validation, rate limiting, CSP, tokens |
| `docs/FILE_BASED_ROUTING.md` | Route files, dynamic params, codegen |
| `docs/WIRE_PROTOCOL.md` | All 12 WebSocket message types with JSON examples |
| `docs/EFFECTS.md` | Effects, timers, server functions, async patterns |
| `docs/MIDDLEWARE.md` | HTTP middleware pipeline, scoping, built-ins |
| `docs/STATE_MANAGEMENT.md` | Stores, PubSub, dynamic subscriptions |
| `docs/COMPONENTS.md` | Composable MVU units |
| `docs/TESTING.md` | Unit, runtime, sim, and CDP tests |
| `docs/ERROR_HANDLING.md` | Error types, recovery, user experience |
| `docs/DEPLOYMENT.md` | Production config, Docker, health checks |
| `docs/HTML_ELEMENTS.md` | Element helpers, attributes, events |
| `docs/TODO.md` | Issues and deferred items |

## Commands

```sh
gleam build    # Must exit 0 with zero warnings
gleam test     # Must exit 0 with all tests passing
gleam run      # Run the application
```

## Engineering Principles

Non-negotiable. Every change must follow these.

### No Error Swallowing

- **Never** discard, ignore, or silently catch errors.
- Every error must be explicitly handled or propagated via `Result`.
- No catch-all patterns that hide failures.
- Use `let assert` only when the invariant is truly guaranteed. Document why.

### Log Everything

- All significant state transitions, errors, warnings, and decisions must be logged.
- Use structured logging with context (module, function, relevant IDs).
- Log at appropriate levels: `error` for failures, `warning` for unexpected-but-handled, `info` for state transitions, `debug` for tracing.

### TigerStyle (see [docs/TIGERSTYLE.md](docs/TIGERSTYLE.md))

- Assert invariants aggressively. Crash early, crash loudly.
- No "temporary" hacks or workarounds. Fix the root cause.
- Test the unhappy paths as thoroughly as the happy paths.

### No Fallbacks

- **Never** add fallback behavior unless the user explicitly approves it.
- If something fails, it fails loudly. Do not silently degrade.
- Fallbacks hide bugs.

### No Shortcuts

- Stability and correctness over velocity.
- Prefer simple, correct code over clever code.
- Every change should leave the codebase better than you found it.

### No Invented Patterns

- Check reference repos before designing: Lustre (MVU/Effects), LiveView (diff protocol, SSR), Reflex (dirty-var tracking), Squirrel (codegen pattern), Glance (AST parsing).
- Adapt proven patterns to Gleam rather than inventing from scratch.

## Work Completion Standard

### Definition of Done (ALL must be true)

1. `gleam build` exits 0 with **zero warnings**
2. `gleam test` exits 0 with **all tests passing**
3. `docs/PROGRESS.md` is updated — completed tasks checked off
4. No debug leftovers, no `todo` or `panic` in shipped code
5. All new code has error handling, logging, and assertions per principles above

### Ralph Loop Protocol

1. **FIRST ACTION:** Read `docs/PROGRESS.md` to know where you are
2. Find the next unchecked task in the current milestone
3. Implement properly — follow engineering principles
4. Run `gleam build` and `gleam test` — fix everything until green
5. Update `docs/PROGRESS.md`
6. If blocked, document in PROGRESS.md and move to next task

### Failure Mode Prevention

- **Don't rewrite working code.** Read existing files before making changes.
- **Don't guess at APIs.** Check source code for correct function signatures.
- **Don't skip tests.** Every module needs tests. Test unhappy paths too.
- **Don't forget logging.** Public functions in transport/runtime should log.
- **Don't leave broken state.** If `gleam build` fails, fix it before doing anything else.
- **Don't add deps without checking.** Verify packages exist on Hex first.
