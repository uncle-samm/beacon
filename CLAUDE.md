# Beacon

A full-stack Gleam web framework inspired by TanStack Start, Phoenix LiveView, Lustre, and Reflex.dev.

## Language & Platform

- **Language:** Gleam (dual-target: Erlang/BEAM + JavaScript)
- **Runtime:** BEAM (OTP actors, one process per session)
- **Build system:** `gleam` CLI + custom build-time code generation tools

## Engineering Principles

These are non-negotiable. Every contributor and tool (including AI) must follow them.

### No Error Swallowing

- **Never** discard, ignore, or silently catch errors.
- Every error must be explicitly handled or propagated via `Result`.
- No catch-all patterns that hide failures. If a case arm handles an "other" case, it must log and/or return a meaningful error — not silently succeed.
- Use `let assert` only when the invariant is truly guaranteed. Document why.

### Log Everything

- All significant state transitions, errors, warnings, and decisions must be logged.
- Use structured logging with context (module, function, relevant IDs).
- Log at appropriate levels: `error` for failures, `warning` for unexpected-but-handled cases, `info` for state transitions, `debug` for detailed tracing.
- In development, default to verbose logging. In production, allow configuration.

### TigerBeetle Approach

- Deterministic, reproducible behavior is paramount.
- Assertions are not optional — assert invariants aggressively. If something "can't happen," assert it. When it does happen, you'll know immediately instead of chasing a downstream symptom.
- Crash early, crash loudly. A crash with a clear assertion message is infinitely better than silent corruption.
- No "temporary" hacks or workarounds. Fix the root cause.
- Test the unhappy paths as thoroughly as the happy paths.

### Proper Assertions

- Use `let assert` with descriptive patterns for expected invariants.
- For runtime validation, use explicit checks that return `Result` with descriptive error types.
- Never use `todo` or `panic` in shipped code — these are development placeholders only.
- Custom error types must carry enough context to diagnose the failure without a debugger.

### Custom Linting (Made in Gleam)

- Build and maintain a custom linting tool written in Gleam (using Glance for AST parsing).
- The linter enforces the rules above: no swallowed errors, required logging at module boundaries, assertion coverage, banned patterns.
- The linter runs in CI and must pass before merge.
- Rules are documented and versioned alongside the framework code.

### No Shortcuts

- Do not rush. Stability and correctness over velocity.
- No "quick fixes" that paper over the real problem.
- If a fix feels hacky, step back and find the proper solution.
- Every change should leave the codebase better than you found it.
- Prefer simple, correct code over clever code.

### Documentation of Work

- Maintain a `CHANGELOG.md` tracking completed work, decisions, and how issues were resolved.
- TODOs in code must reference a tracking issue or be documented in `docs/TODO.md` with context.
- When fixing a bug, document: what broke, why, and how the fix prevents recurrence.
- Architecture decisions go in `docs/adr/` as lightweight decision records.

## Reference Repos — Use Their Patterns, Don't Reinvent

Do not invent new patterns when a referenced repo already has a proper solution. Always check these first and adapt their approach to Gleam:

| Repo | What to reference it for |
|------|--------------------------|
| **Lustre** | MVU architecture, Element type, Effect system, server components, VDOM diff |
| **Phoenix LiveView** | Diff protocol (static/dynamic splitting, fingerprints), SSR pipeline (dead render + live mount), morphdom, event clocking, Rendered struct wire format |
| **Reflex.dev** | Dirty-var tracking, state sharding/substates, computed var caching + dependency tracking, event chain model (single-event-at-a-time) |
| **Squirrel** | Build-time code generation pattern (CLI tool via `gleam run -m`, check mode for CI, dev dependency, scan conventional locations) |
| **Leptos** | Server functions (`#[server]`), per-route SSR modes (streaming, async, partially-blocked), Suspense boundaries, islands architecture |
| **Dioxus** | LiveView rendering mode, server functions, `use_server_future` pattern |
| **Livewire** | Alpine.js morph plugin, `$wire` proxy for client-server transparency, "entangle" for bidirectional state sync, morph look-ahead algorithm |
| **Sprocket** | React-like hooks alternative in Gleam, client-side DOM patching runtime |
| **Lissome** | Lustre-to-LiveView bridge (proof that BEAM-to-browser pipeline works) |
| **Glance** | Gleam AST parser — used for all code generation and static analysis |
| **Surface** | Compile-time component prop/slot validation on top of LiveView |
| **gserde** | JSON serialization codegen pattern in Gleam |

Before designing any subsystem, research how the relevant reference repo implements it. Adapt their proven pattern rather than designing from scratch.

## Work Completion Standard

IMPORTANT: These rules apply to every session, especially Ralph Loop iterations.

### Never Stop Early

- Never say "this should work" — **verify it works** by running the build and tests.
- Never output a completion promise until ALL checks pass.
- If something breaks while fixing something else, fix that too. Follow the chain.

### Definition of Done (ALL must be true)

1. `gleam build` exits 0 with **zero warnings**
2. `gleam test` exits 0 with **all tests passing**
3. Custom linter passes (if it exists)
4. `docs/PROGRESS.md` is updated — completed tasks checked off, notes added
5. No debug leftovers, no `todo` or `panic` in shipped code
6. All new code has error handling, logging, and assertions per engineering principles

### Ralph Loop Protocol

When running in a Ralph Loop:

1. **FIRST ACTION EVERY ITERATION:** Read `docs/PROGRESS.md` to know where you are
2. Find the next unchecked task in the current milestone
3. Implement it properly (read reference repos, follow engineering principles)
4. Run `gleam build` and `gleam test` — fix everything until green
5. Update `docs/PROGRESS.md` — check off completed tasks, add notes
6. If blocked, document fully in PROGRESS.md Blockers section and move to next task
7. If the current milestone is complete, move to the next milestone
8. **NEVER** emit the completion promise unless ALL milestones are done AND all checks pass

### Failure Mode Prevention

- **Don't rewrite working code.** Read existing files before making changes.
- **Don't guess at APIs.** Check Gleam package docs or source code for correct function signatures.
- **Don't skip tests.** Every module needs tests. Test unhappy paths too.
- **Don't forget logging.** Every public function in transport/runtime/diff should log.
- **Don't invent patterns.** Check reference repos first (see table above).
- **Don't leave broken state.** If `gleam build` fails, fix it before doing anything else.
- **Don't add deps without checking.** Verify package names and versions exist on Hex before adding to gleam.toml.

## Key Files

| File | Purpose |
|------|---------|
| `CLAUDE.md` | This file — engineering rules, read every session |
| `docs/ARCHITECTURE.md` | Full technical architecture document — the blueprint |
| `docs/PROGRESS.md` | **Persistent progress tracker — read FIRST every Ralph Loop iteration** |
| `docs/TODO.md` | Issues, bugs, deferred items with full context |

## Architecture Overview

### Core Layers

1. **Transport** — WebSocket via Mist, actor-per-connection
2. **Runtime** — MVU (Model-View-Update) loop, one BEAM process per session
3. **View** — Element tree (Lustre-compatible API), compiled to JS for client or HTML for server
4. **Diffing** — Three-level hybrid: template-level splitting, VDOM diffing, state dirty-tracking
5. **Routing** — File-based, type-safe, build-time code generation (Squirrel pattern)
6. **SSR** — Dead render (HTTP) then live mount (WebSocket) with hydration
7. **Server Functions** — Effect.server() for server-only operations callable from client

### Key Dependencies

| Layer | Library | Purpose |
|-------|---------|---------|
| HTTP/WS | mist | Server, WebSocket, SSE |
| Web | wisp | Middleware, routing, body parsing |
| UI/VDOM | lustre | MVU, Element type, Effect system |
| AST | glance | Source parsing for code generation |
| AST output | glance_printer | Pretty-print generated code |
| SQL | squirrel | Pattern reference for codegen |
| JSON | gleam_json | Wire format encoding/decoding |
| OTP | gleam_otp | Actors, supervisors, subjects |

### Build Order (Milestones)

1. Server component over WebSocket (Mist + Lustre VDOM diff)
2. Dead render + hydration (SSR pipeline)
3. Type-safe file-based router (code generation with Glance)
4. Template-level optimizations (static/dynamic splitting)
5. State management (dirty-var tracking, substates as actors, computed vars)
6. Server functions + DX polish (hot reload, error recovery, reconnection)

## Commands

```sh
gleam build    # Build the project
gleam test     # Run tests
gleam run      # Run the application
```

## Project Structure (Planned)

```
src/
  beacon/           # Framework core
    transport/       # WebSocket, connection management
    runtime/         # MVU loop, session process
    view/            # Element type, rendering
    diff/            # VDOM diffing, template splitting
    router/          # Route matching, code generation
    ssr/             # Server-side rendering, hydration
    effect/          # Effect system (client + server)
    lint/            # Custom linter (Glance-based)
  routes/            # User-defined routes (file-based)
  generated/         # Auto-generated route types
test/
  beacon/            # Tests mirror src structure
docs/
  adr/               # Architecture decision records
  TODO.md            # Tracked TODOs with context
```
