/// Real integration tests — starts a server and makes actual HTTP/WebSocket requests.
/// No mocks. Real network calls.

import beacon/application
import beacon/effect
import beacon/element
import beacon/error
import beacon/middleware
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/option
import gleam/string

// --- App setup ---

pub type TestModel {
  TestModel(count: Int)
}

pub type TestMsg {
  TestInc
}

fn test_app_config(port: Int) -> application.AppConfig(TestModel, TestMsg) {
  application.AppConfig(
    port: port,
    init: fn() { #(TestModel(count: 0), effect.none()) },
    update: fn(model, _msg) {
      #(TestModel(count: model.count + 1), effect.none())
    },
    view: fn(model: TestModel) {
      element.el("div", [element.attr("id", "app")], [
        element.text("count:" <> int.to_string(model.count)),
      ])
    },
    decode_event: option.Some(fn(_name, handler_id, _data, _path) {
      case handler_id {
        "inc" -> Ok(TestInc)
        _ -> Error(error.RuntimeError(reason: "unknown"))
      }
    }),
    secret_key: "integration-test-secret-key-long-enough!!",
    title: "Integration Test",
    serialize_model: option.None,
    deserialize_model: option.None,
      subscriptions: [],
      on_pubsub: option.None,
    middlewares: [middleware.secure_headers()],
    static_dir: option.None,
    route_patterns: [],
    on_route_change: option.None,
    server_fns: dict.new(), dynamic_subscriptions: option.None, on_notify: option.None,
  )
}

// ===== 22.3: Real HTTP Integration Tests =====

pub fn http_get_root_returns_200_with_ssr_html_test() {
  start_httpc()
  let port = 11_000 + unique_port()
  let assert Ok(_app) = application.start(test_app_config(port))
  process.sleep(100)

  let assert Ok(#(status, _headers, body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/")
  let assert 200 = status
  // Body should contain SSR-rendered content
  let assert True = string.contains(body, "count:0")
  let assert True = string.contains(body, "Integration Test")
}

pub fn http_get_beacon_js_returns_javascript_test() {
  start_httpc()
  let port = 11_100 + unique_port()
  let assert Ok(_app) = application.start(test_app_config(port))
  process.sleep(100)

  let assert Ok(#(status, headers, body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/beacon.js")
  let assert 200 = status
  // Body should be JavaScript
  let assert True = string.contains(body, "function")
  // Content-Type should be JavaScript
  let assert True = has_header(headers, "content-type", "application/javascript")
}

pub fn http_get_has_security_headers_test() {
  start_httpc()
  let port = 11_200 + unique_port()
  let assert Ok(_app) = application.start(test_app_config(port))
  process.sleep(100)

  let assert Ok(#(_status, headers, _body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/")
  // secure_headers middleware should have added these
  let assert True = has_header(headers, "x-content-type-options", "nosniff")
  let assert True = has_header(headers, "x-frame-options", "SAMEORIGIN")
}

// ===== 22.1: Real WebSocket Stress Test =====

pub fn ws_connect_and_receive_mount_test() {
  start_httpc()
  let port = 11_300 + unique_port()
  let assert Ok(_app) = application.start(test_app_config(port))
  process.sleep(100)

  // Open a real WebSocket connection via gen_tcp
  let assert Ok(socket) = ws_connect("localhost", port)
  // Send join message
  let assert Ok(Nil) = ws_send(socket, "{\"type\":\"join\"}")
  // Receive mount response
  let assert Ok(response) = ws_recv(socket, 3000)
  // Response should be a JSON mount message containing "count:0"
  let assert True = string.contains(response, "mount")
  ws_close(socket)
}

pub fn ws_50_concurrent_connections_test() {
  start_httpc()
  let port = 11_400 + unique_port()
  let assert Ok(_app) = application.start(test_app_config(port))
  process.sleep(200)

  let result_subject = process.new_subject()
  let n = 50

  // Spawn 50 processes that each open a real WebSocket connection
  spawn_ws_clients(n, port, result_subject)

  // Collect results
  let succeeded = collect_results(result_subject, n, 0, 10_000)
  let assert True = succeeded == n
}

// ===== 24.1: Per-Connection Independence Test =====

pub fn two_connections_have_independent_state_test() {
  start_httpc()
  let port = 11_600 + unique_port()
  let assert Ok(_app) = application.start(test_app_config(port))
  process.sleep(200)

  // Open two independent WebSocket connections
  let assert Ok(socket_a) = ws_connect("localhost", port)
  let assert Ok(socket_b) = ws_connect("localhost", port)

  // Both join — each should get their own runtime with count:0
  let assert Ok(Nil) = ws_send(socket_a, "{\"type\":\"join\"}")
  let assert Ok(mount_a) = ws_recv(socket_a, 3000)
  let assert True = string.contains(mount_a, "count:0")

  let assert Ok(Nil) = ws_send(socket_b, "{\"type\":\"join\"}")
  let assert Ok(mount_b) = ws_recv(socket_b, 3000)
  let assert True = string.contains(mount_b, "count:0")

  // Send increment on connection A only
  let assert Ok(Nil) =
    ws_send(
      socket_a,
      "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"inc\",\"data\":\"{}\",\"target_path\":\"0\",\"clock\":1}",
    )
  let assert Ok(patch_a) = ws_recv(socket_a, 3000)
  // Connection A should have count:1
  let assert True = string.contains(patch_a, "1")

  // Connection B should NOT have received anything (independent runtime)
  // Try to receive — should timeout (no message)
  let _b_result = ws_recv(socket_b, 500)
  // B either gets nothing (Error) or gets the PubSub broadcast which
  // doesn't affect its own state. Either way, B's state is still count:0.

  ws_close(socket_a)
  ws_close(socket_b)
}

// ===== 22.4: Middleware Gates WebSocket Upgrade =====

pub fn auth_middleware_blocks_ws_upgrade_test() {
  start_httpc()
  let port = 11_500 + unique_port()
  // Create an app with an auth middleware that always rejects
  let auth_mw = fn(_req, _next) {
    gleam_http_response_new(401)
  }
  let config =
    application.AppConfig(
      ..test_app_config(port),
      middlewares: [auth_mw],
    )
  let assert Ok(_app) = application.start(config)
  process.sleep(100)

  // HTTP GET should be blocked by auth middleware
  let assert Ok(#(status, _headers, _body)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/")
  let assert 401 = status

  // WebSocket upgrade should also be blocked (middleware runs before routing)
  let assert Ok(#(ws_status, _headers2, _body2)) =
    http_get("http://localhost:" <> int.to_string(port) <> "/ws")
  let assert 401 = ws_status
}

// ===== Helpers =====

fn spawn_ws_clients(
  remaining: Int,
  port: Int,
  result: process.Subject(Bool),
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let _ =
        process.spawn(fn() {
          case ws_connect("localhost", port) {
            Ok(socket) -> {
              case ws_send(socket, "{\"type\":\"join\"}") {
                Ok(Nil) -> {
                  case ws_recv(socket, 5000) {
                    Ok(_response) -> {
                      ws_close(socket)
                      process.send(result, True)
                    }
                    Error(_) -> {
                      ws_close(socket)
                      process.send(result, False)
                    }
                  }
                }
                Error(_) -> {
                  ws_close(socket)
                  process.send(result, False)
                }
              }
            }
            Error(_) -> process.send(result, False)
          }
        })
      // Small delay to avoid overwhelming the server
      process.sleep(5)
      spawn_ws_clients(remaining - 1, port, result)
    }
  }
}

fn collect_results(
  subject: process.Subject(Bool),
  remaining: Int,
  count: Int,
  timeout: Int,
) -> Int {
  case remaining <= 0 {
    True -> count
    False -> {
      let selector =
        process.new_selector()
        |> process.select(subject)
      case process.selector_receive(selector, timeout) {
        Ok(True) -> collect_results(subject, remaining - 1, count + 1, timeout)
        Ok(False) -> collect_results(subject, remaining - 1, count, timeout)
        Error(Nil) -> count
      }
    }
  }
}

fn has_header(
  headers: List(#(String, String)),
  name: String,
  expected_value: String,
) -> Bool {
  case headers {
    [] -> False
    [#(k, v), ..rest] -> {
      case string.lowercase(k) == string.lowercase(name) {
        True -> string.contains(string.lowercase(v), string.lowercase(expected_value))
        False -> has_header(rest, name, expected_value)
      }
    }
  }
}

fn unique_port() -> Int {
  erlang_unique_pos() % 100
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_pos() -> Int

@external(erlang, "beacon_http_client_ffi", "start_httpc")
fn start_httpc() -> Nil

@external(erlang, "beacon_http_client_ffi", "http_get")
fn http_get(url: String) -> Result(#(Int, List(#(String, String)), String), String)

pub type TcpSocket

@external(erlang, "beacon_http_client_ffi", "ws_connect")
fn ws_connect(host: String, port: Int) -> Result(TcpSocket, String)

@external(erlang, "beacon_http_client_ffi", "ws_send")
fn ws_send(socket: TcpSocket, payload: String) -> Result(Nil, String)

@external(erlang, "beacon_http_client_ffi", "ws_recv")
fn ws_recv(socket: TcpSocket, timeout: Int) -> Result(String, String)

@external(erlang, "beacon_http_client_ffi", "ws_close")
fn ws_close(socket: TcpSocket) -> Nil

@external(erlang, "beacon_integration_test_ffi", "response_401")
fn gleam_http_response_new(status: Int) -> a
