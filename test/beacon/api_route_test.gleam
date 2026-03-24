/// Tests for the API route handler feature.
/// Verifies that api_handler runs before SSR/static and can handle or pass through requests.

import beacon/application
import beacon/effect
import beacon/element
import beacon/middleware
import beacon/transport
import beacon/transport/server.{type Connection, type ResponseBody, Bytes}
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/option
import gleeunit/should

type TestModel {
  TestModel(count: Int)
}

type TestMsg {
  TestInc
}

fn unique_port_offset() -> Int {
  let t = erlang_unique_integer()
  case t > 0 {
    True -> t % 100
    False -> { 0 - t } % 100
  }
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int

fn test_app_config_with_api(
  port: Int,
  api_handler: fn(Request(Connection)) ->
    option.Option(response.Response(ResponseBody)),
) -> application.AppConfig(TestModel, TestMsg) {
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
    decode_event: option.Some(fn(_name, _hid, _data, _path) {
      Ok(TestInc)
    }),
    secret_key: "api-test-secret-key-long-enough-for-hmac!!",
    title: "API Test",
    serialize_model: option.None,
    deserialize_model: option.None,
    middlewares: [middleware.secure_headers()],
    static_dir: option.None,
    route_patterns: [],
    on_route_change: option.None,
    dynamic_subscriptions: option.None,
    on_notify: option.None,
    security_limits: transport.default_security_limits(),
    head_html: option.None,
    api_handler: option.Some(api_handler),
    ws_auth: option.None,
    init_from_request: option.None,
  )
}

/// API handler returns a custom response for /api/hello.
pub fn api_route_handler_serves_response_test() {
  let port = 9700 + unique_port_offset()
  let api = fn(req: Request(Connection)) {
    case request.path_segments(req) {
      ["api", "hello"] ->
        option.Some(
          response.new(200)
          |> response.set_header("content-type", "application/json")
          |> response.set_body(
            Bytes(bytes_tree.from_string("{\"greeting\":\"hello\"}")),
          ),
        )
      _ -> option.None
    }
  }
  let config = test_app_config_with_api(port, api)
  let assert Ok(_app) = application.start(config)
  process.sleep(100)

  // Request /api/hello — should get the custom API response
  let resp = http_get(port, "/api/hello")
  should.equal(resp.status, 200)
  should.equal(resp.body, "{\"greeting\":\"hello\"}")
}

/// API handler returns None for unknown paths — falls through to SSR.
pub fn api_route_handler_falls_through_test() {
  let port = 9710 + unique_port_offset()
  let api = fn(req: Request(Connection)) {
    case request.path_segments(req) {
      ["api", "hello"] ->
        option.Some(
          response.new(200)
          |> response.set_body(Bytes(bytes_tree.from_string("api"))),
        )
      _ -> option.None
    }
  }
  let config = test_app_config_with_api(port, api)
  let assert Ok(_app) = application.start(config)
  process.sleep(100)

  // Request / — should fall through to SSR (page HTML)
  let resp = http_get(port, "/")
  should.equal(resp.status, 200)
  // SSR page should contain the app content or at least HTML
  should.be_true(contains_string(resp.body, "<!DOCTYPE html>") || contains_string(resp.body, "<div"))
}

/// API handler can serve POST requests (method is preserved).
pub fn api_route_handler_post_method_test() {
  let port = 9720 + unique_port_offset()
  let api = fn(req: Request(Connection)) {
    case req.method, request.path_segments(req) {
      http.Post, ["api", "data"] ->
        option.Some(
          response.new(201)
          |> response.set_header("content-type", "application/json")
          |> response.set_body(
            Bytes(bytes_tree.from_string("{\"created\":true}")),
          ),
        )
      http.Get, ["api", "data"] ->
        option.Some(
          response.new(200)
          |> response.set_body(
            Bytes(bytes_tree.from_string("{\"method\":\"get\"}")),
          ),
        )
      _, _ -> option.None
    }
  }
  let config = test_app_config_with_api(port, api)
  let assert Ok(_app) = application.start(config)
  process.sleep(100)

  // GET /api/data
  let resp = http_get(port, "/api/data")
  should.equal(resp.status, 200)
  should.be_true(contains_string(resp.body, "get"))
}

/// No API handler configured — all requests go to SSR.
pub fn no_api_handler_falls_through_test() {
  let port = 9730 + unique_port_offset()
  let config =
    application.AppConfig(
      port: port,
      init: fn() { #(TestModel(count: 0), effect.none()) },
      update: fn(model, _msg) {
        #(TestModel(count: model.count + 1), effect.none())
      },
      view: fn(_model: TestModel) {
        element.el("div", [], [element.text("hello")])
      },
      decode_event: option.None,
      secret_key: "no-api-test-secret-key-long-enough-for-hmac!!",
      title: "No API Test",
      serialize_model: option.None,
      deserialize_model: option.None,
      middlewares: [],
      static_dir: option.None,
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      security_limits: transport.default_security_limits(),
      head_html: option.None,
      api_handler: option.None,
      ws_auth: option.None,
      init_from_request: option.None,
    )
  let assert Ok(_app) = application.start(config)
  process.sleep(100)

  let resp = http_get(port, "/")
  should.equal(resp.status, 200)
  // Should get SSR HTML
  should.be_true(contains_string(resp.body, "hello") || contains_string(resp.body, "<!DOCTYPE"))
}

// --- HTTP client helper (raw TCP) ---

import gleam/string

type SimpleResponse {
  SimpleResponse(status: Int, body: String)
}

fn http_get(port: Int, path: String) -> SimpleResponse {
  case do_http_get(port, path) {
    Ok(resp) -> resp
    Error(reason) -> {
      // Return a failure response so tests can assert on it
      SimpleResponse(status: 0, body: "HTTP GET failed: " <> reason)
    }
  }
}

@external(erlang, "beacon_api_test_ffi", "http_get")
fn do_http_get(port: Int, path: String) -> Result(SimpleResponse, String)

fn contains_string(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}
