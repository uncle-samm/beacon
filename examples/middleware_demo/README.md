# Middleware Demo

Route-scoped middleware with auth, API versioning, and health checks.

## Features

- `middleware.only("/admin", ...)` -- admin auth requiring X-Admin header
- `middleware.at("/healthz", ...)` -- exact-path health check endpoint
- `middleware.methods([Post, Put], ...)` -- method-scoped blocking
- Global logger middleware on all requests

## Run

```bash
cd examples/middleware_demo
gleam run
```

Open http://localhost:8080 -- the main page shows a counter; try `/healthz` for the JSON health check.
