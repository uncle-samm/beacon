# Changelog

All notable changes to the Beacon framework are documented here.

## [0.2.0] - 2026-03-16 — P1 Production Readiness

### Added
- `beacon/session.gleam` — ETS-backed cookie sessions
- `beacon/auth.gleam` — login/logout/current_user, require_auth middleware, CSRF middleware
- Form validation: email, max_length, matches, validate pipeline
- Form rendering: password_input, textarea, select helpers
- Asset fingerprinting and immutable cache headers
- `/health` endpoint returning `{"status":"ok"}`
- `beacon/config.gleam` — environment config (PORT, SECRET_KEY, BEACON_ENV)
- Dockerfile with multi-stage build and HEALTHCHECK
- Getting started guide, architecture overview, CHANGELOG

## [0.1.0] - 2026-03-15 — P0 Core Architecture

### Added
- MVU runtime with per-connection BEAM processes (like LiveView)
- Client-side local execution — LOCAL events produce ZERO WebSocket traffic
- Build tool: Glance analysis → JS compilation → esbuild bundle
- Model sync: server sends authoritative Model after events
- Error recovery: fallback to server-only, resync on reconnect
- URL routing with `:param` segments, SPA navigation, back/forward
- Server functions: named RPC via WebSocket
- Shared state via auto-broadcasting stores + PubSub
- LiveView-style Rendered format (statics/dynamics diffing)
- Handler registry (eliminates decode_event boilerplate)
- SSR with hydration, DOM morphing
- Middleware pipeline: CORS, compression, rate limiting, security headers, request ID
- 30+ HTML element helpers
- WebSocket transport with heartbeat and reconnection
- Supervision trees and error boundaries
- 418 tests, zero warnings
