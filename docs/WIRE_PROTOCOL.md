# Wire Protocol

Beacon communicates over WebSocket at `/ws` using JSON messages with a `type` discriminator.

## Client Messages (browser to server)

**join** -- Sent after WebSocket opens. Optional `token` for state recovery, `path` for routing.
```json
{"type": "join", "token": "", "path": "/"}
```

**event** -- DOM event. `handler_id` maps to the view's handler. `clock` is monotonic. `ops` is client-computed patch (empty string if none).
```json
{"type": "event", "name": "click", "handler_id": "increment", "data": "{}", "target_path": "0.1.0", "clock": 5, "ops": ""}
```

**event_batch** -- Atomic batch (LOCAL events replayed before MODEL event).
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

## Server Messages (server to browser)

**mount** -- Initial SSR HTML after `join`.
```json
{"type": "mount", "payload": "<div>...</div>"}
```

**model_sync** -- Full authoritative model state. Sent on join.
```json
{"type": "model_sync", "model": "{\"count\":1}", "version": 1, "ack_clock": 1}
```

**patch** -- Incremental JSON Patch ops. Sent after events when model changes.
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
2. Client sends `join` with saved token.
3. Server validates token age (max 24h) and deserializes model.
4. Success: `mount` with recovered state. Failure: uses current model.

## Security

- Messages above `max_message_bytes` (64KB) rejected with error.
- Non-heartbeat events rate-limited to `max_events_per_second` (50/sec).
- Global connection limit: 10,000 (HTTP 503 when full).
- Origin header checked to prevent cross-site WebSocket hijacking.
