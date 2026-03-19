/// Beacon's effect system.
/// Effects are descriptions of side effects that the runtime will execute.
/// Following Lustre's design: effects are data, not actions.
///
/// Reference: Lustre's effect.gleam — same pattern (opaque type, from/none/batch),
/// but Beacon's is simpler: only synchronous effects with dispatch callback.

import gleam/erlang/process
import gleam/list

/// An effect is a list of callbacks that will be executed by the runtime.
/// Each callback receives a `dispatch` function to send messages back to
/// the update loop.
pub opaque type Effect(msg) {
  Effect(callbacks: List(fn(fn(msg) -> Nil) -> Nil))
}

/// No effects to perform. Use when update doesn't need side effects.
pub fn none() -> Effect(msg) {
  Effect(callbacks: [])
}

/// Create an effect from a callback function.
/// The callback receives a `dispatch` function that sends messages
/// back to the runtime's update loop.
///
/// Example:
/// ```gleam
/// effect.from(fn(dispatch) {
///   // Do some async work...
///   dispatch(DataLoaded(result))
/// })
/// ```
pub fn from(callback: fn(fn(msg) -> Nil) -> Nil) -> Effect(msg) {
  Effect(callbacks: [callback])
}

/// Combine multiple effects into one. All will be executed.
/// No ordering guarantees between effects in the batch.
pub fn batch(effects: List(Effect(msg))) -> Effect(msg) {
  let all_callbacks =
    list.fold(effects, [], fn(acc, eff) {
      list.append(acc, eff.callbacks)
    })
  Effect(callbacks: all_callbacks)
}

/// Transform the message type of an effect.
/// Useful when composing effects from child components.
pub fn map(effect: Effect(a), f: fn(a) -> b) -> Effect(b) {
  let mapped_callbacks =
    list.map(effect.callbacks, fn(callback) {
      fn(dispatch: fn(b) -> Nil) { callback(fn(a) { dispatch(f(a)) }) }
    })
  Effect(callbacks: mapped_callbacks)
}

/// Execute all callbacks in the effect with the given dispatch function.
/// Called by the runtime — not by user code.
pub fn perform(effect: Effect(msg), dispatch: fn(msg) -> Nil) -> Nil {
  list.each(effect.callbacks, fn(callback) { callback(dispatch) })
}

/// Create a background effect that runs in a separate BEAM process.
/// Unlike `from`, this doesn't block the main update loop.
/// The callback runs in a spawned process and can dispatch messages back.
///
/// Reference: Reflex `rx.event(background=True)`.
///
/// Example:
/// ```gleam
/// effect.background(fn(dispatch) {
///   let data = expensive_database_query()
///   dispatch(DataLoaded(data))
/// })
/// ```
pub fn background(callback: fn(fn(msg) -> Nil) -> Nil) -> Effect(msg) {
  Effect(callbacks: [
    fn(dispatch) {
      let _ = process.spawn(fn() { callback(dispatch) })
      Nil
    },
  ])
}

/// Maximum concurrent timers per runtime process.
/// Prevents runaway timer creation from buggy update handlers.
const max_timers = 10

/// Create a periodic timer effect. Dispatches `make_msg()` every `interval_ms`.
/// The timer runs in a separate BEAM process and continues until the runtime shuts down.
/// Capped at 10 concurrent timers per runtime — additional timers are rejected with a warning.
///
/// Reference: Phoenix LiveView `Process.send_after` in `handle_info`.
///
/// Example:
/// ```gleam
/// effect.every(150, fn() { Tick })  // game loop at ~7fps
/// effect.every(1000, fn() { RefreshStats })  // dashboard update every second
/// ```
pub fn every(interval_ms: Int, make_msg: fn() -> msg) -> Effect(msg) {
  Effect(callbacks: [
    fn(dispatch) {
      let current = get_timer_count()
      case current >= max_timers {
        True -> {
          log_timer_limit_warning(current)
          Nil
        }
        False -> {
          increment_timer_count()
          let _ =
            process.spawn(fn() { timer_loop(interval_ms, make_msg, dispatch) })
          Nil
        }
      }
    },
  ])
}

/// Get the current timer count from the process dictionary.
/// Effects execute inside the runtime process, so the count is per-runtime.
@external(erlang, "beacon_effect_ffi", "get_timer_count")
fn get_timer_count() -> Int

/// Increment the timer count in the process dictionary.
@external(erlang, "beacon_effect_ffi", "increment_timer_count")
fn increment_timer_count() -> Nil

/// Log a warning when the timer limit is reached.
@external(erlang, "beacon_effect_ffi", "log_timer_limit_warning")
fn log_timer_limit_warning(current: Int) -> Nil

fn timer_loop(
  interval_ms: Int,
  make_msg: fn() -> msg,
  dispatch: fn(msg) -> Nil,
) -> Nil {
  process.sleep(interval_ms)
  dispatch(make_msg())
  timer_loop(interval_ms, make_msg, dispatch)
}

/// Create a single delayed effect. Dispatches `make_msg()` once after `delay_ms`.
///
/// Example:
/// ```gleam
/// effect.after(3000, fn() { HideNotification })
/// ```
pub fn after(delay_ms: Int, make_msg: fn() -> msg) -> Effect(msg) {
  Effect(callbacks: [
    fn(dispatch) {
      let _ =
        process.spawn(fn() {
          process.sleep(delay_ms)
          dispatch(make_msg())
        })
      Nil
    },
  ])
}

/// Check if an effect has any callbacks to execute.
pub fn is_none(effect: Effect(msg)) -> Bool {
  list.is_empty(effect.callbacks)
}
