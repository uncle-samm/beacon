/// Beacon's effect system.
/// Effects are descriptions of side effects that the runtime will execute.
/// Following Lustre's design: effects are data, not actions.
///
/// Reference: Lustre's effect.gleam — same pattern (opaque type, from/none/batch),
/// but Beacon's is simpler: only synchronous effects with dispatch callback.
import gleam/erlang/process
import gleam/int
import gleam/list

/// An effect is a list of callbacks that will be executed by the runtime.
/// Each callback receives a `dispatch` function to send messages back to
/// the update loop.
pub opaque type Effect(msg) {
  Effect(callbacks: List(Callback(msg)))
}

type Callback(msg) {
  SimpleCallback(run: fn(fn(msg) -> Nil) -> Nil)
  KeyedCallback(key: String, run: fn(fn(msg) -> Nil) -> Nil)
  SpawnedCallback(run: fn(fn(msg) -> Nil) -> process.Pid)
  KeyedSpawnedCallback(key: String, run: fn(fn(msg) -> Nil) -> process.Pid)
  CancelKeyCallback(key: String)
}

pub opaque type Cancel {
  Cancel(key: String)
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
  Effect(callbacks: [SimpleCallback(run: callback)])
}

/// Associate an effect with a stable key so stale async completions can be dropped.
pub fn keyed(key: String, inner: Effect(msg)) -> Effect(msg) {
  Effect(
    callbacks: list.map(inner.callbacks, fn(callback) {
      case callback {
        SimpleCallback(run) -> KeyedCallback(key: key, run: run)
        KeyedCallback(_, run) -> KeyedCallback(key: key, run: run)
        SpawnedCallback(run) -> KeyedSpawnedCallback(key: key, run: run)
        KeyedSpawnedCallback(_, run) -> KeyedSpawnedCallback(key: key, run: run)
        CancelKeyCallback(cancel_key) -> CancelKeyCallback(key: cancel_key)
      }
    }),
  )
}

/// Wrap an effect in a generated cancel key and return the cancel token.
pub fn cancellable(inner: Effect(msg)) -> #(Effect(msg), Cancel) {
  let key = "cancel_" <> int.to_string(unique_integer())
  #(keyed(key, inner), Cancel(key: key))
}

/// Cancel a previously created cancellable effect token.
pub fn cancel(token: Cancel) -> Effect(msg) {
  Effect(callbacks: [CancelKeyCallback(key: token.key)])
}

/// Combine multiple effects into one. All will be executed.
/// No ordering guarantees between effects in the batch.
pub fn batch(effects: List(Effect(msg))) -> Effect(msg) {
  let all_callbacks =
    list.fold(effects, [], fn(acc, eff) { list.append(acc, eff.callbacks) })
  Effect(callbacks: all_callbacks)
}

/// Transform the message type of an effect.
/// Useful when composing effects from child components.
pub fn map(effect: Effect(a), f: fn(a) -> b) -> Effect(b) {
  let mapped_callbacks =
    list.map(effect.callbacks, fn(callback) {
      case callback {
        SimpleCallback(run) ->
          SimpleCallback(run: fn(dispatch: fn(b) -> Nil) {
            run(fn(a) { dispatch(f(a)) })
          })
        KeyedCallback(key, run) ->
          KeyedCallback(key: key, run: fn(dispatch: fn(b) -> Nil) {
            run(fn(a) { dispatch(f(a)) })
          })
        SpawnedCallback(run) ->
          SpawnedCallback(run: fn(dispatch: fn(b) -> Nil) {
            run(fn(a) { dispatch(f(a)) })
          })
        KeyedSpawnedCallback(key, run) ->
          KeyedSpawnedCallback(key: key, run: fn(dispatch: fn(b) -> Nil) {
            run(fn(a) { dispatch(f(a)) })
          })
        CancelKeyCallback(key) -> CancelKeyCallback(key: key)
      }
    })
  Effect(callbacks: mapped_callbacks)
}

/// Execute all callbacks in the effect with the given dispatch function.
/// Called by the runtime — not by user code.
pub fn perform(
  effect: Effect(msg),
  dispatch: fn(msg) -> Nil,
  dispatch_keyed: fn(String, Int, msg) -> Nil,
) -> Nil {
  let _ = perform_tracked(effect, dispatch, dispatch_keyed)
  Nil
}

/// Execute callbacks and return framework-owned spawned process IDs.
/// The runtime uses this to kill timers/background work during shutdown.
pub fn perform_tracked(
  effect: Effect(msg),
  dispatch: fn(msg) -> Nil,
  dispatch_keyed: fn(String, Int, msg) -> Nil,
) -> List(process.Pid) {
  list.fold(effect.callbacks, [], fn(pids, callback) {
    case callback {
      SimpleCallback(run) -> {
        run(dispatch)
        pids
      }
      KeyedCallback(key, run) -> {
        let generation = register_key_generation(key)
        run(fn(message) { dispatch_keyed(key, generation, message) })
        pids
      }
      SpawnedCallback(run) -> [run(dispatch), ..pids]
      KeyedSpawnedCallback(key, run) -> {
        let generation = register_key_generation(key)
        [run(fn(message) { dispatch_keyed(key, generation, message) }), ..pids]
      }
      CancelKeyCallback(key) -> {
        cancel_key_generation(key)
        pids
      }
    }
  })
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
    SpawnedCallback(run: fn(dispatch) {
      process.spawn_unlinked(fn() { callback(dispatch) })
    }),
  ])
}

/// Maximum concurrent timers per runtime process.
/// Prevents runaway timer creation from buggy update handlers.
const max_timers = 10

/// Create a periodic timer effect. Dispatches `make_msg()` every `interval_ms`.
/// The timer runs in a separate BEAM process and continues until the runtime shuts down.
/// Capped at 10 concurrent timers per runtime — additional timers are rejected with a warning.
///
/// Note: each call creates a NEW timer. Guard against duplicate calls in update.
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
    SpawnedCallback(run: fn(dispatch) {
      let current = live_timer_count()
      case current >= max_timers {
        True -> {
          log_timer_limit_warning(current)
          process.spawn_unlinked(fn() { Nil })
        }
        False -> {
          let pid =
            process.spawn_unlinked(fn() {
              timer_loop(interval_ms, make_msg, dispatch)
            })
          register_timer(pid)
          pid
        }
      }
    }),
  ])
}

/// Count live timers for this runtime, pruning any that have exited.
/// Effects execute inside the runtime process, so the count is per-runtime.
/// Self-healing: timers that died free up slots, so the cap can never
/// permanently lock out new timers (unlike a monotonic counter).
@external(erlang, "beacon_effect_ffi", "live_timer_count")
fn live_timer_count() -> Int

/// Track a spawned timer pid so it counts toward the live limit.
@external(erlang, "beacon_effect_ffi", "register_timer")
fn register_timer(pid: process.Pid) -> Nil

/// Log a warning when the timer limit is reached.
@external(erlang, "beacon_effect_ffi", "log_timer_limit_warning")
fn log_timer_limit_warning(current: Int) -> Nil

@external(erlang, "beacon_effect_ffi", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "beacon_effect_ffi", "register_key_generation")
fn register_key_generation(key: String) -> Int

@external(erlang, "beacon_effect_ffi", "cancel_key_generation")
fn cancel_key_generation(key: String) -> Nil

@external(erlang, "beacon_effect_ffi", "is_current_key_generation")
pub fn is_current_key_generation(key: String, generation: Int) -> Bool

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
    SpawnedCallback(run: fn(dispatch) {
      process.spawn_unlinked(fn() {
        process.sleep(delay_ms)
        dispatch(make_msg())
      })
    }),
  ])
}

/// Check if an effect has any callbacks to execute.
pub fn is_none(effect: Effect(msg)) -> Bool {
  list.is_empty(effect.callbacks)
}
