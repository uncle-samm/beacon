import beacon/middleware
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/string
import mist

// --- Pipeline tests ---

pub fn pipeline_empty_passes_through_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert 200 = resp.status
}

pub fn pipeline_single_middleware_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
  }
  let mw = fn(req, next) {
    let resp = next(req)
    response.set_header(resp, "x-test", "added")
  }
  let piped = middleware.pipeline([mw], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert Ok("added") = response.get_header(resp, "x-test")
}

pub fn pipeline_order_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
  }
  // First middleware adds "1", second adds "2"
  let mw1 = fn(req, next) {
    let resp = next(req)
    response.set_header(resp, "x-order", "1")
  }
  let mw2 = fn(req, next) {
    let resp = next(req)
    response.set_header(resp, "x-second", "2")
  }
  let piped = middleware.pipeline([mw1, mw2], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert Ok("1") = response.get_header(resp, "x-order")
  let assert Ok("2") = response.get_header(resp, "x-second")
}

pub fn pipeline_short_circuit_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
  }
  // Auth middleware that always rejects
  let auth_mw = fn(_req, _next) {
    response.new(401)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("unauthorized")))
  }
  let piped = middleware.pipeline([auth_mw], handler)
  let req = make_request("GET", "/protected")
  let resp = piped(req)
  let assert 401 = resp.status
}

// --- Secure headers tests ---

pub fn secure_headers_sets_x_content_type_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.secure_headers()], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert Ok("nosniff") =
    response.get_header(resp, "x-content-type-options")
  let assert Ok("SAMEORIGIN") =
    response.get_header(resp, "x-frame-options")
}

// --- Request ID tests ---

pub fn request_id_adds_header_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.request_id()], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert Ok(id) = response.get_header(resp, "x-request-id")
  // ID should start with "req_"
  let assert True = string.starts_with(id, "req_")
}

pub fn request_id_unique_per_request_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.request_id()], handler)
  let req = make_request("GET", "/")
  let resp1 = piped(req)
  let resp2 = piped(req)
  let assert Ok(id1) = response.get_header(resp1, "x-request-id")
  let assert Ok(id2) = response.get_header(resp2, "x-request-id")
  let assert True = id1 != id2
}

// --- Body parser tests ---

pub fn body_parser_passes_small_body_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.body_parser(1_000_000)], handler)
  let req = make_request_with_header("POST", "/api", "content-length", "100")
  let resp = piped(req)
  let assert 200 = resp.status
}

pub fn body_parser_rejects_oversized_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.body_parser(1000)], handler)
  let req =
    make_request_with_header("POST", "/api", "content-length", "2000000")
  let resp = piped(req)
  let assert 413 = resp.status
}

pub fn body_parser_passes_no_content_length_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.body_parser(1000)], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert 200 = resp.status
}

// --- Compression tests ---

pub fn compress_adds_gzip_header_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_header("content-type", "text/html; charset=utf-8")
    |> response.set_body(
      mist.Bytes(bytes_tree.from_string("<html><body>Hello World!</body></html>")),
    )
  }
  let piped = middleware.pipeline([middleware.compress()], handler)
  let req = make_request_with_header("GET", "/", "accept-encoding", "gzip, deflate")
  let resp = piped(req)
  let assert Ok("gzip") = response.get_header(resp, "content-encoding")
  let assert Ok("Accept-Encoding") = response.get_header(resp, "vary")
}

pub fn compress_skips_without_accept_encoding_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_header("content-type", "text/html")
    |> response.set_body(
      mist.Bytes(bytes_tree.from_string("<html>Hello</html>")),
    )
  }
  let piped = middleware.pipeline([middleware.compress()], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert Error(Nil) = response.get_header(resp, "content-encoding")
}

pub fn compress_skips_binary_content_test() {
  let handler = fn(_req) {
    response.new(200)
    |> response.set_header("content-type", "image/png")
    |> response.set_body(
      mist.Bytes(bytes_tree.from_string("binary data")),
    )
  }
  let piped = middleware.pipeline([middleware.compress()], handler)
  let req = make_request_with_header("GET", "/img", "accept-encoding", "gzip")
  let resp = piped(req)
  // Should NOT compress binary content
  let assert Error(Nil) = response.get_header(resp, "content-encoding")
}

// --- Context tests ---

pub fn context_set_and_get_test() {
  let ctx = middleware.new_context()
  let ctx = middleware.set_context(ctx, "user_id", "123")
  let assert Ok("123") = middleware.get_context(ctx, "user_id")
}

pub fn context_get_missing_test() {
  let ctx = middleware.new_context()
  let assert Error(Nil) = middleware.get_context(ctx, "nope")
}

pub fn context_overwrite_test() {
  let ctx = middleware.new_context()
  let ctx = middleware.set_context(ctx, "role", "user")
  let ctx = middleware.set_context(ctx, "role", "admin")
  let assert Ok("admin") = middleware.get_context(ctx, "role")
}

// --- Rate limit middleware test ---

pub fn rate_limit_middleware_allows_test() {
  let limiter =
    beacon_rate_limit.new(
      "mw_allow_" <> unique_id(),
      beacon_rate_limit.RateLimitConfig(max_requests: 10, window_seconds: 60),
    )
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.rate_limit(limiter)], handler)
  let req = make_request("GET", "/")
  let resp = piped(req)
  let assert 200 = resp.status
}

pub fn rate_limit_middleware_blocks_test() {
  let limiter =
    beacon_rate_limit.new(
      "mw_block_" <> unique_id(),
      beacon_rate_limit.RateLimitConfig(max_requests: 1, window_seconds: 60),
    )
  let handler = fn(_req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
  }
  let piped = middleware.pipeline([middleware.rate_limit(limiter)], handler)
  let req = make_request("GET", "/")
  // First request passes
  let assert 200 = { piped(req) }.status
  // Second request blocked
  let assert 429 = { piped(req) }.status
}

fn unique_id() -> String {
  do_unique_id()
}

@external(erlang, "beacon_test_ffi", "unique_ref")
fn do_unique_id() -> String

import beacon/rate_limit as beacon_rate_limit

// --- Helpers ---

fn make_request(
  method: String,
  path: String,
) -> request.Request(mist.Connection) {
  // Create a minimal request for testing
  // We can't create a real mist.Connection, so we use FFI
  do_make_request(method, path)
}

@external(erlang, "beacon_middleware_test_ffi", "make_request")
fn do_make_request(
  method: String,
  path: String,
) -> request.Request(mist.Connection)

fn make_request_with_header(
  method: String,
  path: String,
  header_name: String,
  header_value: String,
) -> request.Request(mist.Connection) {
  do_make_request_with_header(method, path, header_name, header_value)
}

@external(erlang, "beacon_middleware_test_ffi", "make_request_with_header")
fn do_make_request_with_header(
  method: String,
  path: String,
  header_name: String,
  header_value: String,
) -> request.Request(mist.Connection)
