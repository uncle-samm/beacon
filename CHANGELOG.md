# Changelog

All notable changes to the Beacon framework are documented here.

## [0.1.0] - 2026-03-15

### Added

#### Core Framework
- **Transport layer** (`beacon/transport`) — WebSocket connections via Mist with typed message protocol, heartbeat, exponential backoff reconnection, event clocking
- **MVU Runtime** (`beacon/runtime`) — Server-side Model-View-Update loop as OTP actor, one BEAM process per session, VDOM diffing with cached previous tree
- **Element type** (`beacon/element`) — Virtual DOM nodes (TextNode, ElementNode, MemoNode) with HTML rendering, JSON serialization, HTML escaping
- **Diff engine** (`beacon/diff`) — VDOM tree diffing producing typed patches (ReplaceText, ReplaceNode, InsertChild, RemoveChild, SetAttribute, RemoveAttribute, SetEvent, RemoveEvent), JSON patch wire format
- **Effect system** (`beacon/effect`) — Effects as data with `from`, `none`, `batch`, `map`, `background`, `perform`
- **Structured logging** (`beacon/log`) — Module-prefixed logging at info/debug/warning/error levels
- **Error types** (`beacon/error`) — 9 contextual error variants (TransportError, CodecError, RuntimeError, DiffError, RenderError, RouterError, EffectError, SessionError, ConfigError)

#### Server-Side Rendering
- **SSR module** (`beacon/ssr`) — LiveView-style dead render: init → model → view → HTML with script injection
- **Session tokens** — HMAC-SHA256 signed tokens with expiration via `gleam_crypto`
- **Hydration** — Client JS attaches event listeners to server-rendered DOM without re-rendering

#### Routing
- **Route scanner** (`beacon/router/scanner`) — Scans `src/routes/` directory, parses filenames for dynamic segments (`[slug]` → `:slug`), extracts public functions via Glance AST
- **Code generator** (`beacon/router/codegen`) — Generates typed Route union, `match_route` function, `to_path` function; CLI via `gleam run -m beacon/router/codegen`
- **CI check mode** — `gleam run -m beacon/router/codegen check` validates generated routes are up to date

#### Template Optimization
- **Template analyzer** (`beacon/template/analyzer`) — Glance-based AST analysis classifying view expressions as static or dynamic based on model field dependencies
- **Rendered struct** (`beacon/template/rendered`) — LiveView-style static/dynamic splitting with SHA-256 fingerprinting, positional diff wire format

#### State Management
- **Dirty-var tracking** (`beacon/state`) — Field-level change detection between model states, computed variable caching with dependency tracking
- **Substates** (`beacon/substate`) — OTP actors for state sharding with Get/Update/Set/Shutdown operations
- **State manager** (`beacon/state_manager`) — Session state persistence with in-memory (Dict) and ETS backends

#### Components
- **Component system** (`beacon/component`) — Encapsulated MVU units with `Component(model, msg, parent_msg)` type, message mapping via `map_node`, parent-child composition

#### Server Functions
- **Server functions** (`beacon/server_fn`) — `call` (sync), `call_async` (spawned process), `try_call` (fallible), `stream` (multi-dispatch)

#### Forms
- **Form handling** (`beacon/form`) — Field binding, validation (`validate_required`, `validate_min_length`), CSRF token generation/verification, form rendering helpers

#### Error Pages
- **Error pages** (`beacon/error_page`) — Styled 404/500 pages, development-mode detailed error display, `to_response` HTTP converter

#### Client Runtime
- **JavaScript client** — ~4KB embedded runtime with WebSocket connection, DOM morphing (not innerHTML), event delegation, hydration support, heartbeat, exponential backoff reconnection, event clocking

#### Tooling
- **Custom linter** (`beacon/lint`) — Glance-based AST linter enforcing no-todo and no-panic rules; CLI via `gleam run -m beacon/lint`
- **Counter example** (`beacon/examples/counter`) — Full working demo at `http://localhost:8080` via `gleam run`

### Technical Details
- 243 automated tests across 18 test modules
- Zero compiler warnings
- Gleam 1.14.0 on BEAM/OTP
- Dependencies: gleam_stdlib, gleam_erlang, gleam_otp, gleam_http, gleam_json, gleam_crypto, mist, glance, logging, simplifile
- Lustre removed as dependency — Beacon has its own Element type and rendering
