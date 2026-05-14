# Private Session

Private Session exercises `beacon.Server state` with a public model and private server state.

Use this for browser integration coverage:

- SSR first paint renders only the public model
- Hydration updates the public model from server-authoritative state sync
- Server-only secret constants, audit entries, and private counters do not appear in HTML or generated client JavaScript
- User events can mutate private server state while the `view` only receives `Model`

```sh
gleam run -m private_session
```
