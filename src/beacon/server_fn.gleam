/// Server functions — effects that run exclusively on the server but can be
/// triggered from client code. The result is sent back to the runtime as a message.
///
/// Reference: Leptos #[server] functions, Dioxus server functions,
/// Architecture doc section on Effect.server().

import beacon/effect.{type Effect}
import beacon/log
import gleam/erlang/process

/// Create a server-side effect that runs a function and dispatches the result.
/// The function runs on the server (in the runtime's BEAM process).
/// When it completes, the result is dispatched as a message to the update loop.
///
/// Example:
/// ```gleam
/// server_fn.call(fn() { db.get_user(id) }, fn(user) { UserLoaded(user) })
/// ```
pub fn call(
  function: fn() -> result,
  on_result: fn(result) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    log.debug("beacon.server_fn", "Executing server function")
    let result = function()
    dispatch(on_result(result))
    log.debug("beacon.server_fn", "Server function completed")
  })
}

/// Create a server-side effect that runs asynchronously in a separate process.
/// The result is dispatched back to the runtime when complete.
/// Unlike `call`, this doesn't block the current update cycle.
///
/// Reference: Reflex background events (`rx.event(background=True)`).
pub fn call_async(
  function: fn() -> result,
  on_result: fn(result) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    log.debug("beacon.server_fn", "Spawning async server function")
    let _ =
      process.spawn(fn() {
        let result = function()
        dispatch(on_result(result))
        log.debug("beacon.server_fn", "Async server function completed")
      })
    Nil
  })
}

/// Create a server-side effect that can fail.
/// The function returns a Result, and separate messages are dispatched
/// for success and error cases.
pub fn try_call(
  function: fn() -> Result(ok, err),
  on_ok: fn(ok) -> msg,
  on_error: fn(err) -> msg,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    log.debug("beacon.server_fn", "Executing fallible server function")
    case function() {
      Ok(value) -> {
        dispatch(on_ok(value))
        log.debug("beacon.server_fn", "Server function succeeded")
      }
      Error(err) -> {
        dispatch(on_error(err))
        log.warning("beacon.server_fn", "Server function failed")
      }
    }
  })
}

/// Create a server-side effect that produces multiple messages over time.
/// Useful for streaming results (e.g., pagination, real-time data).
///
/// Reference: Reflex's yielding event handlers that push state deltas
/// after each yield.
pub fn stream(
  function: fn(fn(msg) -> Nil) -> Nil,
) -> Effect(msg) {
  effect.from(fn(dispatch) {
    log.debug("beacon.server_fn", "Starting streaming server function")
    let _ =
      process.spawn(fn() {
        function(dispatch)
        log.debug("beacon.server_fn", "Streaming server function completed")
      })
    Nil
  })
}
