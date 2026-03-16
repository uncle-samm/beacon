import * as $dict from "../../gleam_stdlib/gleam/dict.mjs";
import * as $int from "../../gleam_stdlib/gleam/int.mjs";
import * as $string from "../../gleam_stdlib/gleam/string.mjs";
import { pd_set, pd_get } from "../beacon_client_ffi.mjs";
import {
  Ok,
  Error,
  toList,
  Empty as $Empty,
  prepend as listPrepend,
  CustomType as $CustomType,
} from "../gleam.mjs";

export class HandlerRegistry extends $CustomType {
  constructor(simple, parameterized, next_id) {
    super();
    this.simple = simple;
    this.parameterized = parameterized;
    this.next_id = next_id;
  }
}
export const HandlerRegistry$HandlerRegistry = (simple, parameterized, next_id) =>
  new HandlerRegistry(simple, parameterized, next_id);
export const HandlerRegistry$isHandlerRegistry = (value) =>
  value instanceof HandlerRegistry;
export const HandlerRegistry$HandlerRegistry$simple = (value) => value.simple;
export const HandlerRegistry$HandlerRegistry$0 = (value) => value.simple;
export const HandlerRegistry$HandlerRegistry$parameterized = (value) =>
  value.parameterized;
export const HandlerRegistry$HandlerRegistry$1 = (value) => value.parameterized;
export const HandlerRegistry$HandlerRegistry$next_id = (value) => value.next_id;
export const HandlerRegistry$HandlerRegistry$2 = (value) => value.next_id;

const registry_key = "beacon_handler_registry";

const stack_key = "beacon_handler_stack";

/**
 * Create an empty registry.
 */
export function empty() {
  return new HandlerRegistry($dict.new$(), $dict.new$(), 0);
}

function extract_value(data) {
  let $ = $string.split(data, "\"value\":\"");
  if ($ instanceof $Empty) {
    return "";
  } else {
    let $1 = $.tail;
    if ($1 instanceof $Empty) {
      return "";
    } else {
      let $2 = $1.tail;
      if ($2 instanceof $Empty) {
        let rest = $1.head;
        let $3 = $string.split(rest, "\"");
        if ($3 instanceof $Empty) {
          return "";
        } else {
          let value = $3.head;
          return value;
        }
      } else {
        return "";
      }
    }
  }
}

/**
 * Resolve a handler ID to a Msg value.
 */
export function resolve(registry, handler_id, event_data) {
  let $ = $dict.get(registry.simple, handler_id);
  if ($ instanceof Ok) {
    return $;
  } else {
    let $1 = $dict.get(registry.parameterized, handler_id);
    if ($1 instanceof Ok) {
      let callback = $1[0];
      let value = extract_value(event_data);
      return new Ok(callback(value));
    } else {
      return new Error("Unknown handler: " + handler_id);
    }
  }
}

function pd_set_registry(registry) {
  return pd_set(registry_key, registry);
}

function pd_get_registry() {
  let $ = pd_get(registry_key);
  if ($ instanceof Ok) {
    let r = $[0];
    return r;
  } else {
    return empty();
  }
}

function pd_get_unsafe_registry() {
  let $ = pd_get(registry_key);
  if ($ instanceof Ok) {
    let r = $[0];
    return r;
  } else {
    return empty();
  }
}

/**
 * Register a simple handler — returns sequential ID.
 */
export function register_simple(msg) {
  let registry = pd_get_unsafe_registry();
  let id = "h" + $int.to_string(registry.next_id);
  let new_registry = new HandlerRegistry(
    $dict.insert(registry.simple, id, msg),
    registry.parameterized,
    registry.next_id + 1,
  );
  pd_set_registry(new_registry);
  return id;
}

/**
 * Register a parameterized handler.
 */
export function register_parameterized(callback) {
  let registry = pd_get_unsafe_registry();
  let id = "h" + $int.to_string(registry.next_id);
  let new_registry = new HandlerRegistry(
    registry.simple,
    $dict.insert(registry.parameterized, id, callback),
    registry.next_id + 1,
  );
  pd_set_registry(new_registry);
  return id;
}

function pd_set_raw_registry(value) {
  return pd_set(registry_key, value);
}

function pd_get_stack() {
  let $ = pd_get(stack_key);
  if ($ instanceof Ok) {
    let stack = $[0];
    return stack;
  } else {
    return toList([]);
  }
}

function pd_set_stack(stack) {
  return pd_set(stack_key, stack);
}

/**
 * Start a new render cycle.
 */
export function start_render() {
  let existing = pd_get_registry();
  let stack = pd_get_stack();
  pd_set_stack(listPrepend(existing, stack));
  return pd_set_registry(empty());
}

/**
 * Finish a render cycle. Returns the populated registry.
 */
export function finish_render() {
  let registry = pd_get_unsafe_registry();
  let stack = pd_get_stack();
  if (stack instanceof $Empty) {
    undefined
  } else {
    let prev = stack.head;
    let rest = stack.tail;
    pd_set_raw_registry(prev);
    pd_set_stack(rest)
  }
  return registry;
}
