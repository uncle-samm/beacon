# Privacy Demo

Demonstrates Beacon's server-side privacy features — keeping secrets out of the client JS bundle.

## Features

- `server_` prefix on constants — `server_api_key` and `server_db_url` are stripped from the client bundle
- `pub type Server` — holds API keys and request counts, accessible in `update` but not `view`
- Computed fields — `subtotal`, `total`, and `item_count` are derived from `Model` and synced to the client automatically
- Client-safe constants — `app_title` is referenced by `view` and included in the bundle

## Run

```bash
cd examples/privacy_demo
gleam run
```

Open http://localhost:8080 -- add and clear items to see computed values update.
