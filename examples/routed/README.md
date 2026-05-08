# Routed

Explicit routing with `beacon.route_pages`.

## Features

- Four routes: `/` (counter), `/about` (static), `/settings` (form), `/stats` (state isolation)
- One Beacon app owns the route state and renders the selected page
- Route declarations live in explicitly imported page modules
- The root app still owns `Model` and `Msg`; page modules are generic view/route helpers
- SSR first paint, then generated client rendering from Beacon state updates
- No filesystem route discovery or alternate router runtime path

## Run

```bash
cd examples/routed
gleam run -m main
```

Open http://localhost:8080 -- navigate between /, /about, /settings, and /stats.
