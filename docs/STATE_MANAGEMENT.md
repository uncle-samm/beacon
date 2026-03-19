# State Management

Beacon has three state layers: **Shared** (cross-user), **Server** (per-session), and **Local** (client-only).

## Server State (Model)

Each browser tab gets its own BEAM process holding the Model. Updates go through the server.

```gleam
beacon.app(init, update, view) |> beacon.start(8080)
```

## Local State (Zero Traffic)

Split state into Model (server-synced) and Local (instant, no network). `update` receives `(model, local, msg)` and returns `#(model, local)`. Messages that only change Local run in the browser.

```gleam
beacon.app_with_local(init, init_local, update, view) |> beacon.start(8080)
```

## Shared State (Store)

ETS-backed stores visible to all connections. Auto-broadcasts via PubSub on mutation.

```gleam
import beacon/store
let s = store.new("settings")       // Create store
store.put(s, "theme", "dark")       // Set (auto-broadcasts)
store.get(s, "theme")               // Ok("dark")
store.delete(s, "theme")            // Remove (auto-broadcasts)
```

### List Store

Multiple values per key (ETS bag). Good for chat messages and logs.

```gleam
let msgs = store.new_list("messages")
store.append(msgs, "room1", msg)           // Add value
store.get_all(msgs, "room1")               // All values for key
store.append_many(msgs, "room1", [a, b])   // Bulk insert, broadcasts once
store.delete_all(msgs, "room1")            // Remove all for key
store.append_notify(msgs, room_id, msg, "room:")  // Also broadcasts to "room:{room_id}"
```

## PubSub

Low-level publish/subscribe using Erlang `pg` (works across distributed nodes).

```gleam
import beacon/pubsub
pubsub.subscribe("chat:lobby")
pubsub.broadcast("chat:lobby", Nil)
pubsub.unsubscribe("chat:lobby")
```

## Dynamic Subscriptions

Subscribe to topics derived from the model. The framework diffs subscriptions after each update.

```gleam
beacon.app(init, update, view)
|> beacon.subscriptions(fn(model) { ["room:" <> model.current_room] })
|> beacon.on_notify(fn(topic) { RoomUpdated(topic) })
|> beacon.start(8080)
```

When `model.current_room` changes, the old topic is unsubscribed and the new one subscribed automatically.

## Cross-Route State Sharing

Create a store at module level and reference it from multiple routes. Use `beacon.subscriptions` in each route to react to changes:

```gleam
pub fn cart() { store.new("cart") }  // in shared.gleam
// Route A: store.put(shared.cart(), "items", new_items)
// Route B: store.get(shared.cart(), "items")
```
