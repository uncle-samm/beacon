/// Shared state store — provides ETS-backed storage without user FFI.
/// Stores auto-broadcast via PubSub when data changes.
/// Use `beacon.watch(store, fn() -> msg)` to subscribe to changes.
///
/// - `Store` — key-value (one value per key)
/// - `ListStore` — bag-type (multiple values per key, like chat messages)

import beacon/log
import beacon/pubsub
import beacon/state_manager
import gleam/list

/// A key-value store backed by ETS.
/// Auto-broadcasts on put/delete.
pub type Store(value) {
  Store(manager: state_manager.EtsManager, topic: String)
}

/// Create a new key-value store.
pub fn new(name: String) -> Store(value) {
  log.info("beacon.store", "Creating store: " <> name)
  Store(manager: state_manager.start_ets(name), topic: "store:" <> name)
}

/// Get a value by key.
pub fn get(store: Store(value), key: String) -> Result(value, Nil) {
  state_manager.ets_get(store.manager, key)
}

/// Set a value by key. Auto-broadcasts to watchers.
pub fn put(store: Store(value), key: String, value: value) -> Nil {
  log.debug("beacon.store", "put: " <> key)
  state_manager.ets_put(store.manager, key, value)
  pubsub.broadcast(store.topic, Nil)
}

/// Delete a value by key. Auto-broadcasts to watchers.
pub fn delete(store: Store(value), key: String) -> Nil {
  log.debug("beacon.store", "delete: " <> key)
  state_manager.ets_delete(store.manager, key)
  pubsub.broadcast(store.topic, Nil)
}

/// Count total entries.
pub fn count(store: Store(value)) -> Int {
  state_manager.ets_count(store.manager)
}

/// Get the PubSub topic for this store (used by `beacon.watch`).
pub fn topic(store: Store(value)) -> String {
  store.topic
}

/// A list store backed by ETS bag — multiple values per key.
/// Auto-broadcasts on append/delete.
pub type ListStore(value) {
  ListStore(table: EtsTable, topic: String)
}

/// Opaque ETS table reference for list stores.
pub type EtsTable

/// Create a new list store.
pub fn new_list(name: String) -> ListStore(value) {
  log.info("beacon.store", "Creating list store: " <> name)
  ListStore(table: list_store_new_table(name), topic: "store:" <> name)
}

/// Append a value. Auto-broadcasts to store-level watchers.
pub fn append(store: ListStore(value), key: String, value: value) -> Nil {
  list_store_append_ffi(store.table, key, value)
  pubsub.broadcast(store.topic, Nil)
}

/// Append multiple values at once. Only broadcasts ONCE after all inserts.
/// Use this instead of calling append() in a loop.
pub fn append_many(
  store: ListStore(value),
  key: String,
  values: List(value),
) -> Nil {
  list.each(values, fn(v) { list_store_append_ffi(store.table, key, v) })
  pubsub.broadcast(store.topic, Nil)
}

/// Append a value and broadcast to both the store topic AND a per-key topic.
/// The per-key topic is `prefix <> key` (e.g., "room:" <> "general" = "room:general").
/// Use with `beacon.subscriptions()` for dynamic per-key subscriptions.
pub fn append_notify(
  store: ListStore(value),
  key: String,
  value: value,
  topic_prefix: String,
) -> Nil {
  list_store_append_ffi(store.table, key, value)
  pubsub.broadcast(store.topic, Nil)
  pubsub.broadcast(topic_prefix <> key, Nil)
}

/// Get all values for a key.
pub fn get_all(store: ListStore(value), key: String) -> List(value) {
  list_store_get_all_ffi(store.table, key)
}

/// Delete all values for a key. Auto-broadcasts to store-level watchers.
pub fn delete_all(store: ListStore(value), key: String) -> Nil {
  list_store_delete_ffi(store.table, key)
  pubsub.broadcast(store.topic, Nil)
}

/// Delete all values for a key and broadcast to a per-key topic.
pub fn delete_all_notify(
  store: ListStore(value),
  key: String,
  topic_prefix: String,
) -> Nil {
  list_store_delete_ffi(store.table, key)
  pubsub.broadcast(store.topic, Nil)
  pubsub.broadcast(topic_prefix <> key, Nil)
}

/// Get the PubSub topic for this list store (used by `beacon.watch`).
pub fn list_topic(store: ListStore(value)) -> String {
  store.topic
}

// === Internal FFI ===

@external(erlang, "beacon_store_ffi", "new_list_store")
fn list_store_new_table(name: String) -> EtsTable

@external(erlang, "beacon_store_ffi", "append")
fn list_store_append_ffi(table: EtsTable, key: String, value: value) -> Nil

@external(erlang, "beacon_store_ffi", "get_all")
fn list_store_get_all_ffi(table: EtsTable, key: String) -> List(value)

@external(erlang, "beacon_store_ffi", "delete_key")
fn list_store_delete_ffi(table: EtsTable, key: String) -> Nil
