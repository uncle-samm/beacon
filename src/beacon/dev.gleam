/// Development tools — file watching, hot reload, auto-recompile.
/// Run with: `gleam run -m beacon/dev`
import beacon/log

/// Start the dev server with file watching and hot reload.
/// Watches .gleam files for changes, auto-recompiles, and hot-swaps modules.
pub fn main() {
  log.configure()
  log.info("beacon.dev", "Starting dev server with hot reload...")

  // Start file watcher
  let watch_dirs = ["src"]
  log.info("beacon.dev", "Watching: " <> join_dirs(watch_dirs))

  // Initial build
  log.info("beacon.dev", "Running initial build...")
  case run_build() {
    Ok(Nil) -> log.info("beacon.dev", "Initial build succeeded")
    Error(reason) -> log.error("beacon.dev", "Initial build failed: " <> reason)
  }

  // Choose watch strategy
  case native_watcher_available() {
    True -> {
      log.info("beacon.dev", "Using native file watcher (fswatch/inotifywait)")
      case start_native_watcher(watch_dirs) {
        Ok(Nil) -> native_watch_loop(watch_dirs)
        Error(reason) ->
          log.error("beacon.dev", "Failed to start native watcher: " <> reason)
      }
    }
    False -> {
      log.info(
        "beacon.dev",
        "Native watcher not available, using 500ms polling",
      )
      let _ = get_file_timestamps(watch_dirs)
      poll_watch_loop(watch_dirs)
    }
  }
}

/// Native watch loop — uses fswatch/inotifywait for instant detection.
fn native_watch_loop(dirs: List(String)) -> Nil {
  let changed = poll_native_watcher()
  case changed {
    True -> {
      log.info("beacon.dev", "File change detected (native), recompiling...")
      handle_recompile()
      // Restart watcher for next change
      case start_native_watcher(dirs) {
        Ok(Nil) -> Nil
        Error(reason) ->
          log.error(
            "beacon.dev",
            "Failed to restart native watcher: " <> reason,
          )
      }
      Nil
    }
    False -> Nil
  }
  native_watch_loop(dirs)
}

/// Polling watch loop used when native watcher is unavailable.
fn poll_watch_loop(dirs: List(String)) -> Nil {
  sleep(500)
  case check_for_changes(dirs) {
    True -> {
      log.info("beacon.dev", "File change detected (polling), recompiling...")
      handle_recompile()
    }
    False -> Nil
  }
  poll_watch_loop(dirs)
}

/// Handle recompile + hot swap + client rebuild.
fn handle_recompile() -> Nil {
  case run_build() {
    Ok(Nil) -> {
      log.info("beacon.dev", "Recompile succeeded")
      case hot_swap_modules() {
        Ok(count) ->
          log.info(
            "beacon.dev",
            "Hot-swapped " <> int_to_string(count) <> " module(s)",
          )
        Error(reason) ->
          log.warning("beacon.dev", "Hot swap failed: " <> reason)
      }
      case run_client_build() {
        Ok(Nil) -> log.info("beacon.dev", "Client JS rebuilt")
        Error(reason) ->
          log.warning("beacon.dev", "Client JS rebuild failed: " <> reason)
      }
      // Notify browsers to reload
      case notify_browser_reload() {
        Ok(Nil) -> Nil
        Error(reason) ->
          log.warning(
            "beacon.dev",
            "Browser reload notification failed: " <> reason,
          )
      }
    }
    Error(reason) -> log.error("beacon.dev", "Recompile failed: " <> reason)
  }
}

/// Run `gleam build` and return success/failure.
fn run_build() -> Result(Nil, String) {
  case run_program(".", "gleam", ["build"]) {
    Ok(_output) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// Run client-side JS build.
fn run_client_build() -> Result(Nil, String) {
  case run_program(".", "gleam", ["run", "-m", "beacon/build"]) {
    Ok(_output) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// Hot-swap compiled BEAM modules using Erlang code loading.
fn hot_swap_modules() -> Result(Int, String) {
  do_hot_swap()
}

fn join_dirs(dirs: List(String)) -> String {
  do_join(dirs, "")
}

fn do_join(dirs: List(String), acc: String) -> String {
  case dirs {
    [] -> acc
    [d] -> acc <> d
    [d, ..rest] -> do_join(rest, acc <> d <> ", ")
  }
}

// === FFI ===

@external(erlang, "beacon_dev_ffi", "run_program")
fn run_program(
  cwd: String,
  program: String,
  args: List(String),
) -> Result(String, String)

@external(erlang, "beacon_dev_ffi", "sleep")
fn sleep(ms: Int) -> Nil

@external(erlang, "beacon_dev_ffi", "check_for_changes")
fn check_for_changes(dirs: List(String)) -> Bool

@external(erlang, "beacon_dev_ffi", "get_file_timestamps")
fn get_file_timestamps(dirs: List(String)) -> List(#(String, Int))

@external(erlang, "beacon_dev_ffi", "do_hot_swap")
fn do_hot_swap() -> Result(Int, String)

@external(erlang, "beacon_dev_ffi", "int_to_string")
fn int_to_string(n: Int) -> String

@external(erlang, "beacon_dev_ffi", "native_watcher_available")
fn native_watcher_available() -> Bool

@external(erlang, "beacon_dev_ffi", "start_native_watcher")
fn start_native_watcher(dirs: List(String)) -> Result(Nil, String)

@external(erlang, "beacon_dev_ffi", "poll_native_watcher")
fn poll_native_watcher() -> Bool

@external(erlang, "beacon_dev_ffi", "notify_browser_reload")
fn notify_browser_reload() -> Result(Nil, String)
