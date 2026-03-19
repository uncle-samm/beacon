# Deployment

## Build Step (Required)

Compile client JavaScript before deploying:

```bash
gleam run -m beacon/build
```

This generates `priv/static/beacon_client_<hash>.js` and `beacon_client.manifest`.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | Server listen port |
| `SECRET_KEY` | auto-generated | Session token signing key |
| `BEACON_ENV` | `development` | Set to `production` for prod |

## Secret Key

Always set an explicit key in production. The auto-generated key changes on restart, invalidating all tokens:

```gleam
beacon.app(init, update, view)
|> beacon.secret_key(config.secret_key())
|> beacon.start(config.port())
```

## Security Limits

```gleam
beacon.security_limits(transport.SecurityLimits(
  max_message_bytes: 65_536, max_events_per_second: 100, max_connections: 20_000,
))
```

## Health Check

`GET /health` returns `{"status":"ok"}` with HTTP 200.

## Docker

```dockerfile
FROM ghcr.io/gleam-lang/gleam:v1.9-erlang-27 AS build
WORKDIR /app
COPY . .
RUN gleam deps download && gleam run -m beacon/build && gleam export erlang-shipment

FROM erlang:27-slim
WORKDIR /app
COPY --from=build /app/build/erlang-shipment .
ENV PORT=8080 BEACON_ENV=production
EXPOSE 8080
CMD ["./entrypoint.sh", "run"]
```

## Logging & Connections

Set `BEACON_ENV=production` to suppress debug output. When `max_connections` is reached, new connections get HTTP 503. Origin headers validated to prevent cross-site hijacking.
