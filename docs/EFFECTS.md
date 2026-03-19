# Effects

Effects are descriptions of side effects that the Beacon runtime executes. Following Lustre's design, effects are data -- not actions. The `Effect(msg)` type is opaque and composed via combinators.

## Returning Effects from Update

When using `beacon.app_with_effects`, your `update` function returns a tuple of the new model and an effect:

```gleam
fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Increment -> #(Model(..model, count: model.count + 1), effect.none())
    LoadData -> #(model, effect.background(fn(dispatch) {
      let data = fetch_data()
      dispatch(DataLoaded(data))
    }))
  }
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

For apps using `app_with_local`, use `beacon.on_update` to attach server-only effects that run after update:

```gleam
beacon.app_with_local(init, init_local, update, view)
|> beacon.on_update(fn(model, msg) {
  case msg {
    SaveItem(item) -> effect.from(fn(_) { db.save(item) })
    _ -> effect.none()
  }
})
|> beacon.start(8080)
```

This keeps `update` pure (compilable to JS) while server effects run only on the BEAM.
