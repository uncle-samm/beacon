# Routed Workspace

Routed workspace exercises Beacon's single app routing path with `beacon.route_pages`, Local UI state, server-authoritative Model updates, forms, and navigation.

Use this for browser integration coverage:

- SSR first paint on `/`, `/pipeline`, and `/settings`
- Hydration takeover with the normal generated client renderer
- Local-only state for panels, filters, drafts, and select controls
- Server-authoritative model updates for deploys, incidents, pipeline cards, and saved profile state
- Route transitions through explicit `route.page` manifest entries

```sh
gleam run -m main
```
