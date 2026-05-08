# Beacon Conformance Matrix

Beacon's framework contract is tested through a small set of canonical apps.
Each canonical app must cover a real composition of features, not isolated smoke
checks.

## Canonical Examples

| Example | Contract |
| --- | --- |
| `examples/counter` | Minimal server-authoritative model update |
| `examples/counter_local` | Client-only Local state with zero WebSocket traffic |
| `examples/local_first_form` | Local draft/dropdown state with model submit boundary |
| `examples/private_session` | `app_with_server` privacy and server-only state stripping |
| `examples/routed` | Explicit imported route modules with root-owned `Model`/`Msg` |
| `examples/routed_workspace` | Explicit route-aware app with Local/model state |
| `examples/route_server_workspace` | Explicit route mini-apps with route-local private `Server` state |
| `examples/auth_workspace` | API login/logout, HttpOnly auth cookie, CSRF, `ws_auth`, `ws_init`, route-aware SSR, and server-private session state |

## Required Checks

Every canonical example should be covered by:

- Clean `gleam build` from source.
- Build-pipeline analysis proving the generated client-state bundle shape is supported.
- Server-side integration tests for HTTP, WebSocket, cookies, and security boundaries.
- Browser/CDP tests for SSR first paint, hydration, DOM stability, local-only traffic,
  server-authoritative patches, route navigation, and console errors.

The repeatable browser entrypoint is:

```sh
make browser-canonical
```

That command starts a temporary headless Chrome with CDP enabled and runs the
canonical matrix in both desktop and mobile viewport profiles:

```sh
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py --canonical --viewport desktop
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py --canonical --viewport mobile
```

For a narrower loop, use `make browser-canonical-desktop`,
`make browser-canonical-mobile`, or set `BEACON_CDP_VIEWPORTS`.

CI should run the same command after `gleam build`, `gleam test`, and
`gleam run -m beacon/lint`. Set `CHROME_BIN`, `CDP_PORT`, or `PYTHON_BIN`
explicitly when the CI image does not expose the defaults.

## Auth Workspace Contract

`examples/auth_workspace` is the canonical full-stack auth app. It must keep the
following guarantees:

- `/login` renders without an authenticated session.
- `POST /api/login` requires the login CSRF field, creates a server-side session,
  and sets `beacon_session` as an HttpOnly cookie.
- `GET /api/me` requires `beacon_session`.
- `POST /api/profile` requires the authenticated session and matching CSRF token.
- `POST /api/logout` requires CSRF, deletes the server session, and clears the cookie.
- WebSocket upgrade without `beacon_session` is rejected by `ws_auth`.
- WebSocket upgrade with `beacon_session` initializes model/server state through `ws_init`.
- Server-only fields such as session ID, CSRF token, audit key, and audit log never
  appear in the public client model, DOM, or client bundle.

## Browser Harness Status

`test_all_cdp.py --canonical` contains browser coverage for the canonical
`counter`, `counter_local`, `local_first_form`, `private_session`, `routed`,
`routed_workspace`, `route_server_workspace`, and `auth_workspace` slices. The
browser harness runs through the project-local `.venv` and
`requirements-dev.txt`.

The permanent harness now asserts:

- DOM mutation buckets stay under a fixed threshold instead of only checking final text.
- `layout-shift` entries stay below the accepted cumulative threshold.
- Mobile canonical runs have no horizontal overflow at DOM stability checkpoints.
- Local-only events send zero model WebSocket events.
- Model events receive `patch` or `model_sync` frames and do not receive post-update
  HTML `mount` frames.
- Explicit route apps restore URL and view state through browser back/forward
  and send `navigate` frames from `popstate`.
- Reconnect tests force a real browser WebSocket close, wait for the reconnect
  `join`, then prove the app remains interactive without duplicate model events.
  The forced-close hook is only enabled when the CDP harness injects
  `window.__BEACON_ENABLE_TEST_HOOKS`.

Latest routed slice run:

```sh
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py routed -v
```

Result: 22 passed, 0 failed, 18 skipped. The routed slice asserts SSR first
paint, client-side route navigation, model event state sync/patches, no normal
post-update `mount` frames, static not-found rendering, DOM mutation bucket
limits, and layout-shift limits.

Latest new example slices:

```sh
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py local_first_form -v
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py route_server_workspace -v
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py auth_workspace -v
```

Results:

- `local_first_form`: 10 passed, 0 failed, 20 skipped
- `route_server_workspace`: 11 passed, 0 failed, 20 skipped
- `auth_workspace`: 11 passed, 0 failed, 20 skipped

Latest canonical browser run:

```sh
make browser-canonical-desktop
make browser-canonical-mobile
```

Results:

- `desktop`: 188 passed, 0 failed, 15 skipped
- `mobile`: 196 passed, 0 failed, 15 skipped

Latest route-history/reconnect canonical runs:

```sh
make browser-canonical-desktop
make browser-canonical-mobile
```

Results:

- `desktop`: 227 passed, 0 failed, 15 skipped
- `mobile`: 235 passed, 0 failed, 15 skipped

These runs cover the full canonical matrix with DOM mutation bucket checks,
cumulative layout-shift checks, parsed WebSocket frame assertions, Local-only
no-traffic assertions, server-private bundle/DOM privacy checks, route
navigation, auth API flow, no normal post-update HTML `mount` frames, and
mobile horizontal-overflow checks. The latest route-history/reconnect runs also
cover browser back/forward route restoration and forced WebSocket reconnect for
both unauthenticated and authenticated sessions.
