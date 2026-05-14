# Effects

Effects are descriptions of side effects that the Beacon runtime executes. Following Lustre's design, effects are data -- not actions. The `Effect(msg)` type is opaque and composed via combinators.

## Effects Outside Update

Prefer a pure `update` plus `beacon.on_update` for application side effects.
That shape keeps the generated client renderer predictable: `update` can be
analyzed and compiled for client rendering, while stores, PubSub, HTTP, env
reads, randomness, and other BEAM-only work stay on the server.

`init` returns the initial model and a startup effect. Event-triggered effects
belong in `on_update`; `update` returns only the new `Model`, `Local`, and
`Server` values.

```gleam
fn init() -> #(Model, effect.Effect(Msg)) {
  #(Model(loading: True), effect.background(fn(dispatch) {
    let data = fetch_data()
    dispatch(DataLoaded(data))
  }))
}

fn update(model: Model, local: Nil, server: Nil, msg: Msg) -> #(Model, Nil, Nil) {
  #(handle_msg(model, msg), local, server)
}
```

## Core Functions

**`effect.none()`** -- No side effect. Use when update only changes the model.

**`effect.from(fn(dispatch) { ... })`** -- One-shot synchronous effect. The callback runs in the runtime process and receives a `dispatch` function to send messages back to the update loop.

**`effect.background(fn(dispatch) { ... })`** -- Runs the callback in a separate BEAM process. Does not block the update loop. Use for database queries, HTTP calls, or other I/O.

**`effect.every(interval_ms, fn() { Msg })`** -- Periodic timer that dispatches the message every `interval_ms` milliseconds. Runs in a spawned process. Capped at 10 concurrent timers per runtime; additional timers are rejected with a warning.

**`effect.after(delay_ms, fn() { Msg })`** -- Delayed one-shot. Dispatches the message once after `delay_ms` milliseconds.

**`effect.batch([effect1, effect2])`** -- Combine multiple effects. All callbacks execute with no ordering guarantees between them.

**`effect.map(effect, fn(a) -> b)`** -- Transform the message type. Used internally for component composition.

## Server-Side Effect Handler

Use `beacon.on_update` to attach server-only effects that run after update:

```gleam
beacon.app(init, init_local, beacon.no_server, update, view)
|> beacon.on_update(fn(state, msg) {
  let #(model, _local, _server) = state
  case msg {
    SaveItem(item) -> effect.from(fn(_) { db.save(item) })
    _ -> effect.none()
  }
})
|> beacon.start(8080)
```

This keeps `update` pure (compilable to JS) while server effects run only on the BEAM.
