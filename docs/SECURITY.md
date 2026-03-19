# Security

Beacon includes built-in security protections across the transport, middleware, and SSR layers.

## SecurityLimits

The `SecurityLimits` type in `beacon/transport` controls connection-level protections:

```gleam
pub type SecurityLimits {
  SecurityLimits(
    max_message_bytes: Int,        // Default: 65536 (64KB)
    max_events_per_second: Int,    // Default: 50
    max_connections: Int,          // Default: 10000
  )
}
```

Override defaults via the builder:

```gleam
import beacon
import beacon/transport

beacon.app(init, update, view)
|> beacon.security_limits(transport.SecurityLimits(
  ..transport.default_security_limits(),
  max_connections: 5000,
  max_events_per_second: 100,
))
|> beacon.start(8080)
```

For routed apps, use `beacon.router_security_limits(builder, limits)`.

## Origin Validation

On every WebSocket upgrade, the transport checks the `Origin` header against the `Host` header. If they do not match, the connection is rejected with HTTP 403. Requests without an `Origin` header (non-browser clients, same-origin) are allowed.

## Rate Limiting

**Per-connection (server-side, transport layer):** Each WebSocket connection tracks events per 1-second sliding window. When `max_events_per_second` (default 50) is exceeded, the server sends a `ServerError("Rate limited")` message and drops the event. Heartbeats are exempt from rate limiting.

**HTTP middleware:** The `middleware.rate_limit(limiter)` middleware returns HTTP 429 when a client exceeds the configured request rate. It identifies clients by `X-Forwarded-For` header or request host.

## Message Size Limits

WebSocket text frames exceeding `max_message_bytes` (default 64KB) are rejected before decoding. The server sends a `ServerError("Message too large")` response.

## Connection Limits

Global WebSocket connection count is tracked via ETS. When `max_connections` (default 10,000) is reached, new upgrade requests receive HTTP 503.

## Secure Headers

The `middleware.secure_headers()` middleware (included by default in all apps) sets:

- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: SAMEORIGIN`
- `X-XSS-Protection: 1; mode=block`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy: camera=(), microphone=(), geolocation=()`
- `Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws: wss:`

## Session Tokens

SSR pages embed a signed session token in the `data-beacon-token` attribute. Tokens are created with `crypto.sign_message` using HMAC-SHA256 and contain a JSON payload with a timestamp and version. The `verify_session_token` function checks the signature and rejects tokens older than `max_age_seconds` (default 24 hours / 86400 seconds).

Auto-generated secret keys are warned about at startup. Set an explicit key for production:

```gleam
beacon.app(init, update, view)
|> beacon.secret_key("your-production-secret")
|> beacon.start(8080)
```

## Timer Cap

The effect system caps periodic timers at 10 per runtime process (`effect.every`). Attempts to create additional timers are rejected with a warning log. This prevents runaway timer creation from buggy update handlers.

## Model Size Bounds

The runtime tracks serialized model size. Models exceeding 1MB trigger a warning log. Models exceeding 5MB are rejected to prevent memory exhaustion.

## WebSocket Authentication

Optional custom auth can be added via the transport config's `ws_auth` field. When set, the function runs before the WebSocket upgrade and can reject connections with HTTP 401.
