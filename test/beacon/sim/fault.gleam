/// Fault injection — disrupts active connections during simulation runs.
/// Runs as a separate process that periodically applies faults.

import beacon/log
import beacon/sim/pool.{type WsSocket}
import gleam/erlang/process
import gleam/int

/// Fault injection configuration.
pub type FaultConfig {
  FaultConfig(
    /// Kill a random connection every N ms (0 = disabled)
    kill_interval_ms: Int,
    /// How many connections to kill total
    kill_count: Int,
  )
}

/// Start a fault injector that kills connections from a list of sockets.
/// Returns a Subject to stop the injector.
pub fn start(
  config: FaultConfig,
  sockets: List(WsSocket),
) -> process.Subject(Nil) {
  let stop_subject = process.new_subject()
  process.spawn(fn() {
    inject_loop(config, sockets, stop_subject, 0)
  })
  stop_subject
}

/// Stop the fault injector.
pub fn stop(subject: process.Subject(Nil)) -> Nil {
  process.send(subject, Nil)
}

fn inject_loop(
  config: FaultConfig,
  sockets: List(WsSocket),
  stop: process.Subject(Nil),
  killed: Int,
) -> Nil {
  case killed >= config.kill_count {
    True -> Nil
    False -> {
      process.sleep(config.kill_interval_ms)
      // Check if we should stop
      case process.receive(stop, 0) {
        Ok(Nil) -> Nil
        Error(Nil) -> {
          // Kill the next socket in the list
          case sockets {
            [socket, ..rest] -> {
              log.info(
                "beacon.sim.fault",
                "Killing connection #" <> int.to_string(killed + 1),
              )
              ws_close(socket)
              inject_loop(config, rest, stop, killed + 1)
            }
            [] -> Nil
          }
        }
      }
    }
  }
}

@external(erlang, "beacon_http_client_ffi", "ws_close")
fn ws_close(socket: WsSocket) -> Nil
