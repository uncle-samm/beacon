/// Handler registry — maps generated handler IDs to Msg values.
/// Eliminates the need for manual `decode_event` functions.
///
/// How it works:
/// 1. Before each view render, `start_render()` creates a fresh registry
/// 2. During render, `on_click(Msg)` calls `register_simple(msg)` → returns "h0", "h1", ...
/// 3. After render, `finish_render()` returns the populated registry
/// 4. When a client event arrives, `resolve(registry, handler_id, data)` looks up the Msg
///
/// The process dictionary is used because the view function runs synchronously
/// in a single BEAM process (the runtime actor). No cross-process leaking.

import beacon/error
import gleam/dict.{type Dict}
import gleam/int
import gleam/string

/// A registry mapping handler IDs to Msg values or callbacks.
pub type HandlerRegistry(msg) {
  HandlerRegistry(
    simple: Dict(String, msg),
    parameterized: Dict(String, fn(String) -> msg),
    next_id: Int,
  )
}

/// Create an empty registry.
pub fn empty() -> HandlerRegistry(msg) {
  HandlerRegistry(simple: dict.new(), parameterized: dict.new(), next_id: 0)
}

/// Get the total number of registered handlers (simple + parameterized).
pub fn registry_size(registry: HandlerRegistry(msg)) -> Int {
  dict.size(registry.simple) + dict.size(registry.parameterized)
}

/// Start a new render cycle. Pushes any existing registry onto a stack
/// and creates a fresh one. Safe for nested renders (components).
pub fn start_render() -> Nil {
  let existing = pd_get_registry()
  let stack = pd_get_stack()
  pd_set_stack([existing, ..stack])
  pd_set_registry(empty())
}

/// Finish a render cycle. Returns the populated registry and restores
/// any previous registry from the stack (for nested renders).
pub fn finish_render() -> HandlerRegistry(msg) {
  let registry = pd_get_unsafe_registry()
  let stack = pd_get_stack()
  case stack {
    [prev, ..rest] -> {
      pd_set_raw_registry(prev)
      pd_set_stack(rest)
    }
    [] -> Nil
  }
  registry
}

/// Register a simple handler — stores the Msg value, returns a unique ID.
/// Called by `beacon.on_click(msg)`, `beacon.on_submit(msg)`, etc.
pub fn register_simple(msg: msg) -> String {
  let registry = pd_get_unsafe_registry()
  let id = "h" <> int.to_string(registry.next_id)
  let new_registry =
    HandlerRegistry(
      ..registry,
      simple: dict.insert(registry.simple, id, msg),
      next_id: registry.next_id + 1,
    )
  pd_set_registry(new_registry)
  id
}

/// Register a parameterized handler — stores a callback that takes a String
/// value (e.g., input value) and returns a Msg.
/// Called by `beacon.on_input(fn(value) { SetName(value) })`, etc.
pub fn register_parameterized(callback: fn(String) -> msg) -> String {
  let registry = pd_get_unsafe_registry()
  let id = "h" <> int.to_string(registry.next_id)
  let new_registry =
    HandlerRegistry(
      ..registry,
      parameterized: dict.insert(registry.parameterized, id, callback),
      next_id: registry.next_id + 1,
    )
  pd_set_registry(new_registry)
  id
}

/// Resolve a handler ID to a Msg value.
/// Checks simple handlers first, then parameterized (with value extraction).
pub fn resolve(
  registry: HandlerRegistry(msg),
  handler_id: String,
  event_data: String,
) -> Result(msg, error.BeaconError) {
  case dict.get(registry.simple, handler_id) {
    Ok(msg) -> Ok(msg)
    Error(Nil) -> {
      case dict.get(registry.parameterized, handler_id) {
        Ok(callback) -> {
          let value = extract_value(event_data)
          Ok(callback(value))
        }
        Error(Nil) ->
          Error(error.RuntimeError(
            reason: "Unknown handler: " <> handler_id,
          ))
      }
    }
  }
}

/// Extract the "value" field from event data JSON.
/// Event data looks like `{"value":"text"}`.
fn extract_value(data: String) -> String {
  case string.split(data, "\"value\":\"") {
    [_, rest] -> {
      case string.split(rest, "\"") {
        [value, ..] -> value
        _ -> ""
      }
    }
    _ -> ""
  }
}

// === Process dictionary FFI ===
// Type-safe wrappers around the raw process dictionary.

const registry_key = "beacon_handler_registry"

const stack_key = "beacon_handler_stack"

fn pd_set_registry(registry: HandlerRegistry(msg)) -> Nil {
  pd_set(registry_key, registry)
}

fn pd_get_registry() -> HandlerRegistry(msg) {
  case pd_get(registry_key) {
    Ok(r) -> r
    Error(Nil) -> empty()
  }
}

fn pd_get_unsafe_registry() -> HandlerRegistry(msg) {
  case pd_get(registry_key) {
    Ok(r) -> r
    Error(Nil) -> empty()
  }
}

fn pd_set_raw_registry(value: a) -> Nil {
  pd_set(registry_key, value)
}

fn pd_get_stack() -> List(a) {
  case pd_get(stack_key) {
    Ok(stack) -> stack
    Error(Nil) -> []
  }
}

fn pd_set_stack(stack: List(a)) -> Nil {
  pd_set(stack_key, stack)
}

@external(erlang, "beacon_handler_ffi", "pd_set")
fn pd_set(key: String, value: a) -> Nil

@external(erlang, "beacon_handler_ffi", "pd_get")
fn pd_get(key: String) -> Result(a, Nil)
