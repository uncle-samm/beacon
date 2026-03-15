# Beacon: Full-Stack Gleam Framework — Complete Technical Architecture

A TanStack Start–style full-stack framework in Gleam is feasible today by combining Lustre's MVU runtime and VDOM diffing with Phoenix LiveView's template-level diff protocol, build-time code generation for file-based routing (following the Squirrel pattern), and a hybrid state-diffing strategy that leverages Gleam's type system for end-to-end safety. The BEAM provides the concurrency backbone — one lightweight process per session — while Gleam's dual-target compiler (Erlang + JavaScript) enables true universal components.

This document covers every layer of the architecture with specific recommendations on what to build, what to port, and what to steal from existing frameworks.

---

## 1. Lustre's Architecture: The Natural Starting Point

Lustre (v5.6.0+) implements the Elm architecture (Model-View-Update) in Gleam, targeting both JavaScript and Erlang. Its server component system is the closest existing Gleam analogue to LiveView.

### Core Runtime Loop

The runtime runs on the server as an OTP actor. The `view` function produces an `Element(msg)` tree, which is diffed against the previous tree. Patches are serialized to JSON and streamed to a ~10KB client runtime that applies them to the real DOM. Events flow back from client to server. Crucially, Lustre uses a bring-your-own-transport model — it provides `server_component.runtime_message_decoder()` and `server_component.client_message_to_json()` but leaves WebSocket plumbing to the developer. This means transport is pluggable across WebSocket, Server-Sent Events, or polling.

### The Element Type

The `Element(msg)` type is opaque (`@internal`) and parameterized by message type. Construction uses pure function calls (no templates or JSX), including `element()`, `text()`, `none()`, `fragment()`, and `namespaced()` for SVG/MathML. The Attribute system distinguishes between HTML attributes (rendered to string, set via `setAttribute`) and DOM properties (set directly on the JS object). A `memo` function with `Ref`-based reference equality enables subtree-skipping during diffs — identical to Elm's `lazy` optimization.

### The Effect System

Side effects are treated as data. The `Effect(msg)` type is opaque and constructed via `effect.from(fn(dispatch) -> Nil)`, where the callback receives a `dispatch` function to send messages back to the update loop. Lifecycle-aware variants include `before_paint` (runs after view, before browser paint) and `after_paint` (runs after paint). The `batch` function combines effects without ordering guarantees. For server components, `select` creates fresh OTP Subjects for actor communication, and `emit` instructs connected clients to fire real DOM events.

### FFI Boundary

Gleam code constructs pure data (Element trees). The diff algorithm is implemented in Gleam (compiled to JS on the client target). A reconciler in JavaScript FFI (`.ffi.mjs` files) applies patches to the real DOM. Key FFI files include `spa.ffi.mjs` (client runtime), `vattr.ffi.mjs` (attribute operations), and `equals.ffi.mjs` (reference equality for memo). The server component client runtime is embedded as a string constant in compiled Gleam — no separate file serving needed.

### Patterns Worth Reusing vs. Rebuilding

**Reuse:** The MVU architecture, universal component abstraction (`App(start_args, model, msg)`), transport-agnostic server components, and the opaque Effect system are all well-designed and proven.

**Rebuild:** Lustre lacks a built-in router, has no streaming SSR, requires three separate Gleam projects for full-stack apps (client/server/shared), and its `@internal` opaque types limit extensibility for framework builders. A full-stack framework would need first-class routing, server-side effects (database, file I/O), and a unified project structure.

### Other Gleam UI Projects to Study

**Sprocket** (`bitbldr/sprocket`, v2.0.0) offers an alternative with React-like hooks and its own client-side DOM patching runtime. **Lissome** (`selenil/lissome`) demonstrates bridging Lustre components into Phoenix LiveView via hooks — proof that the BEAM-to-browser pipeline works.

---

## 2. Phoenix LiveView's Diff Protocol: The Efficiency Benchmark

LiveView's wire protocol achieves remarkable compactness through compile-time template splitting — a fundamentally different approach from VDOM diffing that Gleam could adapt at build time.

### The Rendered Struct

At compile time, the HEEx template engine splits every template into a `static` field (list of literal HTML strings) and a `dynamic` field (a function that returns a list of expression results). For `<span class={@class}>Created: <%= format_time(@created_at) %></span>`, the statics become `["<span class=\"", "\">Created:", "</span>"]` and the dynamics evaluate `@class` and `format_time(@created_at)`. Each struct carries a fingerprint — an integer uniquely identifying the template structure. When fingerprints match between renders, only changed dynamic parts are sent.

### Change Tracking

A `__changed__` map in socket assigns tracks which assigns were modified. The template engine instruments each dynamic expression at compile time to check which assigns it depends on. If none of an expression's dependencies appear in `__changed__`, it returns `nil` — skipping both computation and transmission. For comprehensions (loops), a `Comprehension` struct shares static parts across all entries and tracks per-entry variable changes, sending statics only once regardless of collection size.

### The Wire Format

A compact JSON object uses integer keys for dynamic positions. An initial render sends `{"s": ["<h2>", "</h2>", "..."], "0": "title", "1": "content"}` — statics keyed by `"s"`, dynamics by position number. Subsequent diffs send only changed positions: `{"0": "new title"}`. Components use a `"c"` key mapping component IDs (CIDs) to their render data. When multiple components share the same template fingerprint, statics are sent once and subsequent components reference them via `"s": 1` (meaning "use statics from CID 1"). Benchmarks show that for 300 items with one change, LiveView sends approximately 120 bytes versus 7,274 bytes for a naive approach.

### DOM Patching

LiveView uses morphdom, which diffs two real DOM trees (no virtual DOM) in a single pass, matching elements by ID. On initial join, the full `rendered` payload is stored; on diffs, `Rendered.mergeDiff()` deep-merges the diff into cached state, `Rendered.toString()` reconstructs full HTML by zipping statics and dynamics, then `DOM.patch()` creates a temporary DOM element from the HTML string and morphs the real DOM to match. LiveView 1.1+ adds event clocking — each pushed event gets a clock value, and DOM regions are locked while awaiting server acknowledgment.

### WebSocket Transport

Phoenix Channels use a compact V2 array format: `[join_ref, msg_ref, topic, event, payload]`. The topic prefix `"lv:"` identifies LiveView channels. Heartbeats fire every 30 seconds on the `"phoenix"` topic. Reconnection uses exponential backoff, re-joining with a signed session token.

### Porting to Gleam

The diff algorithm itself (fingerprint comparison, positional diff maps) is pure functional code directly translatable to Gleam. The client-side JS (morphdom + rendered state management) is language-agnostic. The critical dependency is compile-time template splitting, which uses Elixir macros. In Gleam, this would require a build-time code generation step. The `mist` or `glisten` libraries can replace Phoenix Channels for WebSocket transport.

---

## 3. Reflex.dev Architecture: The Server-Authoritative Model

Reflex is the most directly relevant model for the "server owns all state, client is a thin rendering layer" architecture. Understanding its internals deeply is critical.

### Event Chain Model

The frontend maintains an event queue of all pending events. Each event consists of three pieces: a client token (unique per browser tab), the event handler name, and arguments. A processing flag ensures only one event is processed at a time — this prevents race conditions with two event handlers modifying state simultaneously. Background events (decorated with `rx.event(background=True)`) bypass this queue and run concurrently.

When an event fires, it's added to the queue. The frontend sends it to the backend over WebSocket. The backend looks up the user's state via a state manager (an in-memory dictionary by default, Redis in production), runs the event handler, then sends back only the dirty vars as a state delta. Every time an event handler returns (or yields, for streaming updates), dirty vars are computed and a delta is pushed.

**What to steal for Gleam:** The single-event-at-a-time processing model maps perfectly to a BEAM process mailbox — messages are processed sequentially by default. Background events map to spawning a new process. The BEAM gives you this for free without explicit queue management.

### Component Compilation

Python component functions compile down to a JSON specification that describes a React component tree. Each Reflex component maps to a React component — many core components are based on Radix. The compilation step transforms Python function calls like `rx.button("Click me", on_click=State.increment)` into a JSON description containing the React component name, props, children, and event bindings. The frontend React app receives this specification and renders it.

**What to steal for Gleam:** You don't need this layer. Gleam's dual-target compilation means your view functions can compile directly to JS that produces DOM nodes (like Lustre already does), or to BEAM code that produces an HTML/VDOM representation for server rendering. No intermediate JSON component spec needed — this is a Python-specific workaround that Gleam's type system eliminates.

### Dirty Var Tracking and Computed Vars

Reflex tracks mutations at the state variable level. Each state class has `dirty_vars` (a set of strings) and `dirty_substates` (a set of strings). When a var is modified in an event handler, it's added to `dirty_vars`. After the handler completes, `get_delta()` serializes only the dirty vars to JSON.

Computed vars (decorated with `@rx.var`) are functions that derive values from base vars. By default (since v0.7.0), computed vars are cached (`cache=True`) and only recomputed when their dependencies change. The dependency tracking system uses `_var_dependencies` — a class-level dict mapping var names to sets of `(state_name, var_name)` tuples that depend on them. When a base var is dirty, all computed vars that depend on it are marked as `_always_dirty_computed_vars` and recalculated.

For async computed vars (new in v0.7.0), `get_state` and `get_var_value` enable cross-state dependency tracking. You can also pass explicit dependencies via the `deps` argument or add them at runtime via `cls.computed_vars[var_name].add_dependency`.

**What to steal for Gleam:** The dependency tracking concept translates beautifully to Gleam's type system. Instead of runtime introspection (`__setattr__` overrides), you could use the Glance parser at build time to statically analyze which fields a computed function reads, generating the dependency graph at compile time. This would be both faster and more reliable than Reflex's runtime approach.

### State Sharding / Substates

Substates allow splitting state across multiple classes to avoid loading and sending the entire state tree on every event. When an event handler is called, Reflex loads the substate containing the handler plus all its parent states and child substates. This means a flat structure (most substates inheriting directly from `rx.State`) performs better than deep nesting.

Key performance implications documented by Reflex: avoid defining computed vars inside states with large amounts of data, since states with computed vars are always loaded to ensure recalculation. Implementing different parts of the app with separate, unconnected states ensures only necessary data is loaded per event.

**What to steal for Gleam:** Model this as separate OTP processes per state domain. Each "substate" is an actor holding a slice of the app state. The session process coordinates between them, only querying the actors relevant to the current event. This gives you isolation, concurrent access for background events, and natural sharding — and the BEAM's message passing handles the coordination.

### The WebSocket Protocol

Reflex's frontend connects via WebSocket to the `/_event` URL on the FastAPI backend. Events are serialized as JSON containing the client token, handler path, and arguments. State deltas come back as flat JSON dicts keyed by dotted paths (e.g., `{"state.count": 5, "state.items": [...]}`). The state manager maintains a mapping from client tokens to their state objects.

---

## 4. SSR and Hydration Strategy

This was a critical gap in the original report. Every serious full-stack framework needs a story for initial page load.

### LiveView's Two-Phase Mount (The Gold Standard for BEAM)

LiveView uses a "dead render" followed by a "live mount." On the initial HTTP GET request, the server calls `mount/3` and `render/1` to produce a fully rendered HTML page — this is a regular HTTP response with no WebSocket involved. The browser receives complete HTML, giving fast "First Meaningful Paint" and SEO compatibility.

The HTML page includes JavaScript that opens a persistent WebSocket connection. On connect, the server spawns a new stateful LiveView process and calls `mount/3` and `render/1` again. This second render produces the initial `rendered` struct (with static/dynamic splitting), which is pushed over WebSocket. The client-side JS stores this as cached state and begins diffing from there.

A key API: `connected?(socket)` lets developers differentiate between the dead render (where expensive data loading can be deferred) and the live render. Complex pages can use `render_with/2` to show a loading placeholder on dead render and load full data only after WebSocket connect.

### What Your Gleam Framework Needs

The SSR pipeline should be:

1. **Dead render:** On HTTP request, run the `init` function with request context, produce initial model, call `view(model)` to get an `Element(msg)` tree, render to HTML string (Lustre already has `element.to_string()` for this), inject the client JS bundle, and serve as a normal HTTP response.

2. **Client bundle injection:** The HTML includes a `<script>` tag loading the Gleam-compiled-to-JS client runtime. This runtime connects via WebSocket.

3. **Live mount:** On WebSocket connect, spawn a BEAM process for this session, reconstruct the model (either from a signed token embedded in the HTML, or by re-running `init`), and send the initial state/rendered diff.

4. **Hydration:** The client runtime receives the initial state and "wakes up" — attaching event listeners to the existing DOM rather than re-rendering. This is the trickiest part. Lustre doesn't currently support hydration. You'd need to implement DOM node matching (walking the server-rendered DOM and attaching reactive bindings to existing nodes instead of creating new ones).

### Lessons from Other Frameworks

**Leptos (Rust)** offers four SSR modes configurable per-route: out-of-order streaming (default, best performance), in-order streaming, async (waits for all data before responding), and partially-blocked (some Suspense boundaries block, others stream). This per-route configurability is worth stealing — different pages have different needs.

**Dioxus (Rust)** uses a `Transportable` trait for types that can be safely sent from server to client during hydration. Server functions use the `#[server]` macro to mark functions that only run on the server but can be called from client code. The framework automatically generates the API endpoint. This is essentially what your Gleam `Effect.server()` pattern would do.

**Livewire (Laravel)** takes a different approach — Livewire v3 uses Alpine.js's morph plugin instead of morphdom, and the entire core is built as Alpine plugins. The `$wire` proxy object lets Alpine (client-side) manipulate Livewire (server-side) state directly. The "entangle" feature keeps an Alpine property and a Livewire property in sync bidirectionally. This client/server entanglement pattern is worth considering for your framework's "island" escape hatch.

---

## 5. Build-Time Code Generation for Type-Safe Routing

Gleam has no macro system by design. The ecosystem has converged on CLI tools invoked via `gleam run -m` that scan conventional file locations and generate plain `.gleam` source files.

### The Squirrel Pattern (Gleam's Gold Standard)

Squirrel (type-safe SQL) places SQL files in `src/**/sql/*.sql`, generates `sql.gleam` in the parent directory via `gleam run -m squirrel`, and connects to a real Postgres database to infer column types mapped to Gleam types. It supports a `check` mode for CI validation and installs as a dev-only dependency. Other projects following this pattern: `gserde` (JSON serialization codegen) and `catppuccin/gleam` (codegen from data files).

### What to Steal from Each Router Framework

**SvelteKit** pioneered scanning `src/routes/` and generating per-route type files. Generation triggers during dev (Vite plugin watches files) or via `npx svelte-kit sync`. Types are generated into `.svelte-kit/types/` and made to appear as siblings via TypeScript's `rootDirs`.

**React Router v7** follows the same pattern — `typegen` generates `+types/*.d.ts` from the route config. Both frameworks gitignore generated files.

**TanStack Router** generates a single `routeTree.gen.ts` containing executable TypeScript that imports route handlers, calls `.update()` with path/parent configuration, and exports typed interfaces. TanStack recommends committing this file to git.

### Recommended Architecture for Gleam

Combine Squirrel's pattern with TanStack's single-file approach:

```
src/routes/
  index.gleam           // pub fn loader(req) -> Response
  blog/
    [slug].gleam        // Dynamic param route
    index.gleam
src/generated/
  routes.gleam          // AUTO-GENERATED: route types + matching
```

The generated `routes.gleam` would contain a `Route` union type with constructors for each route, a `match` function mapping path segments to routes, and a `to_path` function for URL construction. Invoked via `gleam run -m route_gen`, with `gleam run -m route_gen check` for CI, and a file-watcher mode for development.

### Gleam AST Access: Glance Makes This Feasible

The **Glance** parser (`lpil/glance`, v6.0.0) is a full Gleam source code parser written in Gleam itself. It parses source files into a complete AST including `Module`, `Function`, `Expression`, `Pattern`, `Type`, and `CustomType` nodes, all with `Span` location metadata. It's permissive (parses some code the compiler would reject), has 117+ test functions with snapshot testing via Birdie, and is already used by 20+ packages including `gserde`, `sketch_css`, `glerd`, and `exercism_test_runner`.

This means you can write a build tool in Gleam that:

1. Reads route files using Glance to parse the AST
2. Extracts exported `loader`, `action`, and `view` function signatures
3. Parses dynamic route segments from filenames (`[slug].gleam`)
4. Generates the typed `Route` union and matching/construction functions
5. Optionally analyzes view functions to identify static vs. dynamic parts for template splitting

The last point — static/dynamic analysis of view functions — is the ambitious one. Since Gleam view functions use pure function calls (`html.div([], [html.text(model.name)])`) rather than templates, you could use Glance to walk the AST and identify which parts of the element tree depend on model fields (dynamic) versus which are constant (static). This would enable LiveView-style optimizations without macros.

---

## 6. State Diffing: A Three-Level Hybrid

The optimal strategy combines three levels, each handling a different granularity.

### Level 1: Template-Level Splitting (LiveView-Inspired)

A build step pre-analyzes view functions using Glance to separate static HTML from dynamic expressions. Static parts are sent once; subsequent updates send only changed dynamic positions. This is the biggest performance win — for a typical page with mostly static HTML, it reduces wire traffic by 90%+.

### Level 2: VDOM Diffing (Lustre/Elm-Inspired)

For dynamic content within templates, standard tree diffing with memo/lazy optimization. Gleam's immutable data structures enable sound reference-equality checks for subtree skipping. Elm's approach: `Html.Lazy.lazy` stores the view function and arguments as refs; during diffing, refs are compared with `===`; if all match, the subtree diff is skipped entirely.

### Level 3: State Dirty-Tracking (Reflex-Inspired)

Server-side model changes tracked at the field level. Only modified fields trigger re-rendering of dependent view subtrees. In Gleam, use the Glance parser at build time to generate dependency graphs — which view expressions depend on which model fields. At runtime, after an `update` function runs, compare old and new model fields and only re-render subtrees whose dependencies changed.

### Wire Format

Use a custom typed patch protocol (like Lustre's existing format or LiveView's positional diffs) rather than generic JSON Patch. Type information allows compact encoding: enum variants as integers, known field positions as indices. Existing Elixir JSON Patch libraries (`jsonpatch` at 252K+ downloads on Hex, `json_diff_ex` at 165K) can serve as an interop layer.

---

## 7. WebSocket Transport in Gleam

### Mist (Recommended)

**Mist** (`rawhat/mist`) is the primary Gleam HTTP server, built on top of Glisten. It provides first-class WebSocket support with `on_init`, `on_close`, and message handler callbacks. Each WebSocket connection runs as its own OTP actor with a typed `Subject` for sending messages. The API supports both text and binary frames, compression via `gramps/websocket/compression`, and SSL/TLS.

Mist is production-ready and used by Wisp (the most popular Gleam web framework). In benchmarks, Wisp+Mist outperforms Go, Node.js, and Elixir Phoenix+Cowboy. Mist handles HTTP/1.1, HTTP/2, WebSockets, Server-Sent Events, chunked responses, and file serving.

### Glisten (Lower Level)

**Glisten** (`rawhat/glisten`) is the TCP/SSL layer that Mist builds on. Use Glisten directly only if you need custom protocol handling below the HTTP level. For a web framework, Mist is the right abstraction.

### Recommendation

Use Mist. It's the community standard, has the right abstraction level for a framework (HTTP + WebSocket + SSE), and its actor-per-connection model maps perfectly to the "one BEAM process per user session" architecture. You don't need to build a channel abstraction like Phoenix Channels — BEAM processes and Subjects already provide multiplexing.

---

## 8. Frameworks to Steal From: A Shopping List

### Phoenix LiveView → Diff Protocol + SSR Pipeline

**What to take:** The entire rendered struct concept (static/dynamic splitting), the fingerprint-based change detection, the compact integer-keyed wire format, morphdom for client-side DOM patching, the dead-render-then-live-mount SSR strategy, and the event clocking system for optimistic updates.

**What to leave:** Phoenix Channels (overkill for Gleam — use raw WebSocket via Mist), HEEx macros (replace with Glance-based build-time analysis), the Phoenix router (build your own typed one).

### Reflex.dev → State Management Model

**What to take:** The dirty-var tracking concept, the single-event-at-a-time processing model (maps to BEAM process semantics), the substate sharding pattern (maps to separate OTP actors), computed var dependency tracking (but do it at build time via Glance instead of runtime introspection), and the state manager abstraction (in-memory for dev, Redis/ETS for production).

**What to leave:** The Python-to-React compilation pipeline (unnecessary with Gleam's dual targets), the Next.js frontend (you'll have your own client runtime), the `ReflexList`/`ReflexDict` wrapper types for mutation tracking (Gleam is immutable, so you compare old and new values instead).

### Leptos (Rust) → Server Functions + SSR Modes

**What to take:** The `#[server]` function concept where a function can be called identically on client or server but only executes on the server. The per-route SSR mode configuration (out-of-order streaming, in-order, async, partially-blocked). The `Suspense` boundary pattern for streaming. The islands architecture where components are inert on the client unless explicitly opted in.

**What to leave:** Rust-specific concerns like the `Transportable` trait, WASM binary optimization, and the ownership/lifetime system.

### Dioxus (Rust) → LiveView Mode + Server Functions

**What to take:** The LiveView rendering mode concept where the VirtualDOM runs on the server and diffs are sent over WebSocket. Dioxus's server functions (which actually use Leptos's server function crate). The `use_server_future` pattern with `?` for blocking renders.

**What to leave:** The VDOM (you'll use Lustre-style direct DOM or LiveView-style HTML diffing instead), the multi-platform renderer abstraction (you're targeting web only initially).

### Laravel Livewire → Morphing + Client Escape Hatch

**What to take:** Livewire v3's approach of using Alpine.js as the client-side engine, where Alpine plugins handle DOM updates, event listeners, and local state. The `$wire` proxy pattern that lets client-side JS transparently access server-side state. The "entangle" feature for bidirectional client/server state sync. The morph look-ahead algorithm that checks subsequent elements before making changes (prevents common morphing bugs). The HTML comment markers for conditional blocks that guide the morph algorithm.

**What to leave:** PHP/Blade templating, the HTTP-request-per-interaction model (Livewire v2), and the global Livewire object.

### Elixir Surface → Compile-Time Component Validation

**What to take:** Surface's compile-time validation of component props and slots on top of LiveView. This shows that you can add static analysis to a LiveView-like system. The pattern of catching prop type mismatches and missing required props at compile time rather than runtime.

---

## 9. The Critical Unsolved Problem: Build-Time Template Analysis

The single hardest technical challenge is achieving LiveView-level wire efficiency without Elixir's macro system. Here's a concrete proposal:

### Phase 1: Convention-Based Splitting

View functions in Gleam use function calls, not templates. A build tool can use Glance to parse:

```gleam
pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.h1([], [html.text("Welcome")]),           // STATIC
    html.p([], [html.text(model.username)]),        // DYNAMIC (depends on model.username)
    html.button([event.on_click(Increment)], [
      html.text("Count: " <> int.to_string(model.count))  // DYNAMIC (depends on model.count)
    ]),
  ])
}
```

The build tool walks the AST and classifies each element/attribute as static (no references to `model`) or dynamic (references `model` fields). It generates an optimized render function that separates the two, similar to what LiveView's HEEx engine does.

### Phase 2: Incremental Rendering

Using the dependency graph from Phase 1, the runtime only re-evaluates dynamic expressions whose model dependencies actually changed. Combined with Elm-style memo/lazy for subtree skipping, this approaches LiveView's efficiency without macros.

### Feasibility

Glance already provides the full AST with location spans. The analysis is straightforward for simple patterns (direct `model.field` access). It gets harder with computed values, let bindings, and function calls that indirectly depend on model fields. Start with the simple case (which covers 80% of real-world views) and fall back to full re-render for complex expressions.

---

## 10. Ecosystem Building Blocks

| Layer | Library | Status | Notes |
|-------|---------|--------|-------|
| HTTP/WS Server | mist | Production-ready | Built on glisten, actor-per-connection |
| Web Framework | wisp | Production-ready | Middleware, routing, body parsing |
| UI/VDOM | lustre | Production-ready | MVU, server components, dual-target |
| Source Parser | glance (v6.0.0) | Production-ready | Full AST with spans, 20+ dependents |
| AST Printer | glance_printer | Available | Pretty-print Glance AST back to source |
| SQL Codegen | squirrel | Production-ready | Pattern to follow for route codegen |
| JSON Serde Codegen | gserde | Available | Codegen for serialization |
| JSON | gleam_json | Production-ready | Encoding/decoding |
| OTP Actors | gleam_otp | Production-ready | Actors, supervisors, subjects |
| JSON Patch (Elixir) | jsonpatch | Mature (252K DL) | RFC 6902, usable via FFI |
| LiveView Bridge | lissome | Experimental | Lustre ↔ LiveView integration |
| Alternative UI | sprocket | v2.0.0 | React-like hooks for Gleam |

---

## 11. Recommended Build Order

### Milestone 1: "Hello World" Server Component (2-4 weeks)
- WebSocket transport layer using Mist
- Port Lustre's VDOM diff to work over WebSocket
- One BEAM process per connection holding model state
- Messages from client → update → diff → patch back
- No SSR, no routing, no optimizations

### Milestone 2: Dead Render + Hydration (3-4 weeks)
- HTTP handler that renders initial HTML via `element.to_string()`
- Client JS bundle injection
- WebSocket connect → live mount → hydration
- Signed session tokens for state recovery on reconnect

### Milestone 3: Type-Safe Router with Code Generation (2-3 weeks)
- Build tool using Glance to scan `src/routes/`
- Generate Route type, match function, and path constructor
- File watcher for development
- `check` mode for CI

### Milestone 4: Template-Level Optimizations (4-6 weeks)
- Glance-based static/dynamic analysis of view functions
- LiveView-style positional diff wire format
- Fingerprint-based change detection
- morphdom integration on the client

### Milestone 5: State Management (2-3 weeks)
- Dirty-var tracking with build-time dependency graphs
- Substates as separate OTP actors
- Computed vars with caching
- State manager abstraction (in-memory → ETS → Redis)

### Milestone 6: Server Functions + DX Polish (3-4 weeks)
- `Effect.server()` for server-only operations
- Optimistic updates on the client
- Error recovery and reconnection
- Hot code reloading in development
- Documentation and examples

---

## Conclusion

The framework should layer: Lustre's MVU core for the programming model, LiveView's positional diff protocol for wire efficiency, Reflex's dirty-var tracking for state management, Squirrel-style code generation for routing, and Leptos-inspired server functions for the isomorphic story. The BEAM provides per-session processes, supervision, and fault tolerance. Gleam's type system enables end-to-end safety that neither LiveView (dynamic Elixir), Reflex (Python), nor Livewire (PHP) can match.

The biggest architectural bet is whether to extend Lustre or rebuild. Given Lustre's `@internal` opaque types and lack of streaming SSR, a new framework that reuses Lustre's Effect system design and Element construction API while implementing its own optimized server runtime and build-time template analysis is the right call.
