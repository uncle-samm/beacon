# Wire Protocol

Beacon communicates over WebSocket at `/ws` using JSON messages with a `type` discriminator.

## Client Messages (browser to server)

**join** -- Sent after WebSocket opens. `path` drives routing. `token` remains in the JSON shape for direct runtime tests and non-browser clients, but browser join/session recovery uses the HttpOnly `beacon_join_token` cookie from the WebSocket upgrade request.
```json
{"type": "join", "token": "", "path": "/"}
```

**event** -- DOM event. Generated clients resolve `handler_id` in the browser
and put the encoded typed message in `data.__beacon_msg`; the server decodes
that generated event contract and never renders `view` to resolve handlers.
`clock` is monotonic. `ops` is an optional client-computed patch hint (empty
string if none). The server never treats `ops` as authoritative state; it runs
the server-side update and replies with the server-computed model state or patch.
```json
{"type": "event", "name": "click", "handler_id": "h0", "data": "{\"__beacon_msg\":\"{\\\"tag\\\":\\\"Increment\\\"}\",\"__beacon_event\":\"{}\"}", "target_path": "0.1.0", "clock": 5, "ops": ""}
```

**event_batch** -- Bounded batch for explicit non-browser clients that need to
submit multiple server-visible events in one frame. Generated browser clients do
not replay local-only events through this path; local state stays local until a
server-visible event sends its own `event`.
```json
{"type": "event_batch", "events": [{"name": "click", ...}]}
```

**heartbeat** -- Keep-alive, sent every 30s.
```json
{"type": "heartbeat"}
```

**navigate** -- Client-side SPA navigation.
```json
{"type": "navigate", "path": "/about"}
```

**request_sync** -- Client requests a full authoritative model sync after it
cannot safely apply a server patch. The server responds with `model_sync`
without sending a new `mount`.
```json
{"type": "request_sync"}
```

## Server Messages (server to browser)

**mount** -- Reserved HTML remount message. Normal SSR + client-state apps do
not receive `mount` on join or on ordinary updates. First paint comes from HTTP
SSR; live join replies with `model_sync`, and later updates use `model_sync` or
`patch`.
```json
{"type": "mount", "payload": "<div>...</div>"}
```

**model_sync** -- Full authoritative model state. Sent on join and whenever the
server must replace the client's cached model JSON.
```json
{"type": "model_sync", "model": "{\"count\":1}", "version": 1, "ack_clock": 1}
```

**patch** -- Incremental server-computed JSON Patch ops. Sent after events when
model changes and the server can describe the change compactly.
```json
{"type": "patch", "ops": "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":2}]", "version": 2, "ack_clock": 2}
```

**heartbeat_ack** -- Acknowledges heartbeat.
```json
{"type": "heartbeat_ack"}
```

**error** -- Server error (decode failure, rate limiting).
```json
{"type": "error", "reason": "Rate limited"}
```

**navigate** -- Server-initiated redirect.
```json
{"type": "navigate", "path": "/dashboard"}
```

### hard_navigate (server → client)
Full page navigation via `window.location.href`. Unlike `navigate` (which uses pushState),
this triggers a real HTTP request — use when the browser needs to receive HTTP headers
(e.g., Set-Cookie after login).

```json
{"type": "hard_navigate", "path": "/api/auth/session/TOKEN"}
```

**reload** -- Dev mode: tells browser to reload.
```json
{"type": "reload"}
```

## Event Clocking

Each `event` has a monotonic `clock`. The server echoes it back as `ack_clock` on `model_sync` and `patch`, letting the client discard stale responses.

## Reconnection Flow

1. Client reopens WebSocket to `/ws`.
2. Browser sends `join` with an empty token; the cookie is carried by the WebSocket upgrade request.
3. Server validates token age (max 24h) and deserializes model.
4. Success: `model_sync` with recovered state. Failure: uses current model and logs the recovery error.

## Security

- Messages above `max_message_bytes` (64KB) rejected with error.
- Non-heartbeat events rate-limited to `max_events_per_second` (50/sec).
- Global connection limit: 10,000 (HTTP 503 when full).
- Origin header checked to prevent cross-site WebSocket hijacking.
