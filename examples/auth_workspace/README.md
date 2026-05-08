# Auth Workspace

Canonical Beacon auth/session example.

It exercises the framework pieces that must work together in real apps:

- `api_routes` for login, logout, current-user, and profile writes
- `beacon/api` typed route helpers for ordered API route declarations
- `beacon/auth` session helpers for login responses, CSRF-protected routes, logout, and WebSocket auth
- HttpOnly `beacon_session` cookie for application auth
- `ws_auth` via `auth.ws_session_auth` to reject unauthenticated WebSocket upgrades
- `ws_init` to hydrate server/private state from the upgrade request
- `app_with_server` so session IDs, CSRF tokens, and audit keys stay server-only
- Route-aware SSR for `/login`, `/app`, `/settings`, and `/admin`
- Server-authoritative model updates after hydration

Run it:

```sh
cd examples/auth_workspace
gleam run -m auth_workspace
```

Open `http://localhost:8080/login`.
