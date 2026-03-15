/// PubSub — publish/subscribe for broadcasting messages across processes.
/// Uses Erlang's built-in `pg` (process groups) module, which works across
/// distributed BEAM nodes automatically.
///
/// Reference: Phoenix PubSub, Erlang pg module.

import beacon/log
import gleam/erlang/process.{type Pid}
import gleam/list

/// A topic for pub/sub messaging.
pub type Topic =
  String

/// Subscribe the current process to a topic.
/// The process will receive messages broadcast to this topic.
pub fn subscribe(topic: Topic) -> Nil {
  log.debug("beacon.pubsub", "Subscribing to: " <> topic)
  pg_join(topic, process.self())
}

/// Unsubscribe the current process from a topic.
pub fn unsubscribe(topic: Topic) -> Nil {
  log.debug("beacon.pubsub", "Unsubscribing from: " <> topic)
  pg_leave(topic, process.self())
}

/// Broadcast a message to all processes subscribed to a topic.
/// The message is sent to every process in the topic's process group.
pub fn broadcast(topic: Topic, message: msg) -> Nil {
  let members = pg_get_members(topic)
  log.debug(
    "beacon.pubsub",
    "Broadcasting to " <> topic <> " (" <> int_to_string(list.length(members)) <> " subscribers)",
  )
  list.each(members, fn(pid) {
    erlang_send(pid, message)
  })
}

/// Get the number of subscribers for a topic.
pub fn subscriber_count(topic: Topic) -> Int {
  list.length(pg_get_members(topic))
}

/// Ensure the `pg` scope is started.
/// Call this once at application startup.
pub fn start() -> Nil {
  pg_start()
}

// --- Erlang FFI ---

@external(erlang, "beacon_pubsub_ffi", "pg_join")
fn pg_join(topic: String, pid: Pid) -> Nil

@external(erlang, "beacon_pubsub_ffi", "pg_leave")
fn pg_leave(topic: String, pid: Pid) -> Nil

@external(erlang, "beacon_pubsub_ffi", "pg_get_members")
fn pg_get_members(topic: String) -> List(Pid)

@external(erlang, "beacon_pubsub_ffi", "pg_start")
fn pg_start() -> Nil

@external(erlang, "beacon_pubsub_ffi", "erlang_send")
fn erlang_send(pid: Pid, message: msg) -> Nil

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String
