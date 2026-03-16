/// Client-side handler registry — mirrors the server's beacon/handler.gleam
/// but uses JavaScript module-level storage instead of BEAM process dictionary.

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

/// Start a new render cycle.
pub fn start_render() -> Nil {
  let existing = pd_get_registry()
  let stack = pd_get_stack()
  pd_set_stack([existing, ..stack])
  pd_set_registry(empty())
}

/// Finish a render cycle. Returns the populated registry.
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

/// Register a simple handler — returns sequential ID.
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

/// Register a parameterized handler.
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
pub fn resolve(
  registry: HandlerRegistry(msg),
  handler_id: String,
  event_data: String,
) -> Result(msg, String) {
  case dict.get(registry.simple, handler_id) {
    Ok(msg) -> Ok(msg)
    Error(Nil) -> {
      case dict.get(registry.parameterized, handler_id) {
        Ok(callback) -> {
          let value = extract_value(event_data)
          Ok(callback(value))
        }
        Error(Nil) -> Error("Unknown handler: " <> handler_id)
      }
    }
  }
}

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

// === JS FFI for storage ===

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

@external(javascript, "../beacon_client_ffi.mjs", "pd_set")
fn pd_set(key: String, value: a) -> Nil

@external(javascript, "../beacon_client_ffi.mjs", "pd_get")
fn pd_get(key: String) -> Result(a, Nil)
