/// Connection pool — spawns N real WebSocket connections, each executing
/// a scenario against a real Beacon server. Collects metrics atomically.

import beacon/log
import beacon/sim/metrics.{type MetricsTable}
import beacon/sim/scenario.{
  type Action, type Scenario, AbruptDisconnect, Connect, Disconnect, Join,
  SendEvent, SendMalformed, Sleep, WaitForResponse,
}
import gleam/erlang/process
import gleam/int

/// Pool configuration.
pub type PoolConfig {
  PoolConfig(
    /// Number of concurrent connections
    concurrency: Int,
    /// Target host
    host: String,
    /// Target port
    port: Int,
    /// Scenario each connection runs
    scenario: Scenario,
    /// Stagger delay between spawns (ms)
    stagger_ms: Int,
    /// Metrics table for recording results
    metrics: MetricsTable,
  )
}

/// Pool execution result.
pub type PoolResult {
  PoolResult(total: Int, succeeded: Int, failed: Int, duration_ms: Int)
}

/// Opaque WebSocket handle.
pub type WsSocket

/// Run the pool: spawn N processes, each executing the scenario.
pub fn run(config: PoolConfig) -> PoolResult {
  let start = metrics.now_us()
  let result_subject = process.new_subject()

  // Spawn N workers with stagger
  spawn_workers(
    config.concurrency,
    config,
    result_subject,
    0,
  )

  // Collect results
  let #(succeeded, failed) =
    collect_results(result_subject, config.concurrency, 0, 0)

  let duration_us = metrics.now_us() - start
  PoolResult(
    total: config.concurrency,
    succeeded: succeeded,
    failed: failed,
    duration_ms: duration_us / 1000,
  )
}

fn spawn_workers(
  remaining: Int,
  config: PoolConfig,
  result_subject: process.Subject(Bool),
  idx: Int,
) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      let metrics_table = config.metrics
      let host = config.host
      let port = config.port
      let actions = config.scenario.actions

      process.spawn(fn() {
        let ok = execute_scenario(host, port, actions, metrics_table)
        process.send(result_subject, ok)
      })

      case config.stagger_ms > 0 {
        True -> process.sleep(config.stagger_ms)
        False -> Nil
      }

      spawn_workers(remaining - 1, config, result_subject, idx + 1)
    }
  }
}

fn collect_results(
  subject: process.Subject(Bool),
  remaining: Int,
  succeeded: Int,
  failed: Int,
) -> #(Int, Int) {
  case remaining {
    0 -> #(succeeded, failed)
    _ -> {
      case process.receive(subject, 30_000) {
        Ok(True) ->
          collect_results(subject, remaining - 1, succeeded + 1, failed)
        Ok(False) ->
          collect_results(subject, remaining - 1, succeeded, failed + 1)
        Error(Nil) -> {
          // Timeout — count remaining as failed
          log.warning(
            "beacon.sim.pool",
            "Timeout waiting for "
              <> int.to_string(remaining)
              <> " workers",
          )
          #(succeeded, failed + remaining)
        }
      }
    }
  }
}

/// Execute a scenario's actions sequentially. Returns True on success.
fn execute_scenario(
  host: String,
  port: Int,
  actions: List(Action),
  metrics_table: MetricsTable,
) -> Bool {
  execute_actions(host, port, actions, metrics_table, option_none())
}

fn execute_actions(
  host: String,
  port: Int,
  actions: List(Action),
  mt: MetricsTable,
  socket: Option(WsSocket),
) -> Bool {
  case actions {
    [] -> {
      // Clean up socket if still open
      case socket {
        Some(s) -> {
          ws_close(s)
          Nil
        }
        None -> Nil
      }
      True
    }
    [action, ..rest] -> {
      case execute_action(host, port, action, mt, socket) {
        Ok(new_socket) ->
          execute_actions(host, port, rest, mt, new_socket)
        Error(_reason) -> {
          // Clean up on failure
          case socket {
            Some(s) -> {
              ws_close(s)
              Nil
            }
            None -> Nil
          }
          False
        }
      }
    }
  }
}

fn execute_action(
  host: String,
  port: Int,
  action: Action,
  mt: MetricsTable,
  socket: Option(WsSocket),
) -> Result(Option(WsSocket), String) {
  case action {
    Connect -> {
      metrics.increment(mt, "connections_opened")
      case ws_connect(host, port) {
        Ok(s) -> Ok(Some(s))
        Error(reason) -> {
          metrics.increment(mt, "connections_failed")
          Error(reason)
        }
      }
    }

    Join -> {
      case socket {
        Some(s) -> {
          let join_msg =
            "{\"type\":\"join\",\"token\":\"\",\"url\":\"http://"
            <> host
            <> ":"
            <> int.to_string(port)
            <> "/\"}"
          case ws_send(s, join_msg) {
            Ok(_) -> Ok(Some(s))
            Error(reason) -> Error(reason)
          }
        }
        None -> Error("No socket for Join")
      }
    }

    SendEvent(handler_id, data) -> {
      case socket {
        Some(s) -> {
          let t0 = metrics.now_us()
          let event_msg =
            "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\""
            <> handler_id
            <> "\",\"data\":\""
            <> data
            <> "\",\"target_path\":\"0\",\"clock\":1}"
          case ws_send(s, event_msg) {
            Ok(_) -> {
              metrics.increment(mt, "events_sent")
              let latency = metrics.now_us() - t0
              metrics.record_latency(mt, latency)
              Ok(Some(s))
            }
            Error(reason) -> {
              metrics.increment(mt, "events_failed")
              Error(reason)
            }
          }
        }
        None -> Error("No socket for SendEvent")
      }
    }

    WaitForResponse(timeout_ms) -> {
      case socket {
        Some(s) -> {
          case ws_recv(s, timeout_ms) {
            Ok(_payload) -> {
              metrics.increment(mt, "events_acked")
              Ok(Some(s))
            }
            Error(reason) -> Error(reason)
          }
        }
        None -> Error("No socket for WaitForResponse")
      }
    }

    Sleep(ms) -> {
      process.sleep(ms)
      Ok(socket)
    }

    SendMalformed(payload) -> {
      case socket {
        Some(s) -> {
          let _ = ws_send(s, payload)
          Ok(Some(s))
        }
        None -> Error("No socket for SendMalformed")
      }
    }

    Disconnect -> {
      case socket {
        Some(s) -> {
          ws_close(s)
          metrics.increment(mt, "connections_closed")
          Ok(option_none())
        }
        None -> Ok(option_none())
      }
    }

    AbruptDisconnect -> {
      case socket {
        Some(s) -> {
          ws_close(s)
          metrics.increment(mt, "connections_closed")
          Ok(option_none())
        }
        None -> Ok(option_none())
      }
    }
  }
}

// --- Simple Option type (to avoid import issues with gleam/option) ---

type Option(a) {
  Some(a)
  None
}

fn option_none() -> Option(a) {
  None
}

// --- FFI ---

@external(erlang, "beacon_http_client_ffi", "ws_connect")
fn ws_connect(host: String, port: Int) -> Result(WsSocket, String)

@external(erlang, "beacon_http_client_ffi", "ws_send")
fn ws_send(socket: WsSocket, payload: String) -> Result(Nil, String)

@external(erlang, "beacon_http_client_ffi", "ws_recv")
fn ws_recv(socket: WsSocket, timeout: Int) -> Result(String, String)

@external(erlang, "beacon_http_client_ffi", "ws_close")
fn ws_close(socket: WsSocket) -> Nil
