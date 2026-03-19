/// Middleware Demo — demonstrates route-scoped middleware.
/// Shows: only(), except(), at(), methods(), group()
///
/// Routes:
///   /           → main page (public)
///   /admin/*    → requires X-Admin header (protected by middleware)
///   /api/*      → adds X-Api-Version header
///   /healthz    → health check endpoint (exact match)

import beacon
import beacon/html
import beacon/middleware
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import mist

pub type Model {
  Model(count: Int, page: String)
}

pub type Msg {
  Increment
  Decrement
  Navigate(String)
}

pub fn init() -> Model {
  Model(count: 0, page: "home")
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(..model, count: model.count + 1)
    Decrement -> Model(..model, count: model.count - 1)
    Navigate(page) -> Model(..model, page: page)
  }
}

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.div(
    [html.style("font-family:system-ui;max-width:700px;margin:2rem auto;padding:0 1rem")],
    [
      html.h1([], [html.text("Middleware Demo")]),
      html.p([html.style("color:#666")], [
        html.text("Route-scoped middleware: only(), except(), at(), methods(), group()"),
      ]),
      // Counter
      html.div([html.style("margin:1.5rem 0;padding:1rem;background:#f5f5f5;border-radius:8px")], [
        html.h2([], [html.text("Counter: " <> int.to_string(model.count))]),
        html.button(
          [beacon.on_click(Decrement), html.style("padding:8px 16px;margin-right:8px;border:none;border-radius:4px;cursor:pointer")],
          [html.text("-")],
        ),
        html.button(
          [beacon.on_click(Increment), html.style("padding:8px 16px;border:none;border-radius:4px;cursor:pointer")],
          [html.text("+")],
        ),
      ]),
      // Middleware info
      html.div([html.style("margin-top:1.5rem")], [
        html.h2([], [html.text("Active Middleware")]),
        html.ul([], [
          html.li([], [html.text("Logger — global, all requests")]),
          html.li([], [html.text("Admin auth — only /admin/* (checks X-Admin header)")]),
          html.li([], [html.text("API versioning — only /api/* (adds X-Api-Version)")]),
          html.li([], [html.text("POST rate limit — only POST/PUT methods")]),
          html.li([], [html.text("Health check — exact match /healthz")]),
        ]),
      ]),
    ],
  )
}

/// Simple admin auth — checks for X-Admin header.
/// In production you'd check a real session/token.
fn require_admin() -> middleware.Middleware {
  fn(
    req: request.Request(mist.Connection),
    next: fn(request.Request(mist.Connection)) -> response.Response(mist.ResponseData),
  ) -> response.Response(mist.ResponseData) {
    case request.get_header(req, "x-admin") {
      Ok("true") -> next(req)
      _ ->
        response.new(403)
        |> response.set_body(mist.Bytes(bytes_tree.from_string("Forbidden: admin access required")))
    }
  }
}

/// API versioning middleware — adds version header.
fn api_version() -> middleware.Middleware {
  fn(
    req: request.Request(mist.Connection),
    next: fn(request.Request(mist.Connection)) -> response.Response(mist.ResponseData),
  ) -> response.Response(mist.ResponseData) {
    let resp = next(req)
    response.set_header(resp, "x-api-version", "v1")
  }
}

/// Health check handler — returns 200 OK with status.
fn health_handler() -> middleware.Middleware {
  fn(
    _req: request.Request(mist.Connection),
    _next: fn(request.Request(mist.Connection)) -> response.Response(mist.ResponseData),
  ) -> response.Response(mist.ResponseData) {
    response.new(200)
    |> response.set_header("content-type", "application/json")
    |> response.set_body(mist.Bytes(bytes_tree.from_string("{\"status\":\"ok\"}")))
  }
}

/// Simple POST blocker for demo.
fn block_writes() -> middleware.Middleware {
  fn(
    _req: request.Request(mist.Connection),
    _next: fn(request.Request(mist.Connection)) -> response.Response(mist.ResponseData),
  ) -> response.Response(mist.ResponseData) {
    response.new(405)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("Method not allowed")))
  }
}

pub fn main() {
  beacon.app(init, update, view)
  |> beacon.title("Middleware Demo")
  // Global: logger on all requests
  |> beacon.with_middleware(middleware.logger())
  // /healthz: intercepts and returns JSON (exact path match)
  |> beacon.with_middleware(middleware.at("/healthz", health_handler()))
  // /admin/*: requires X-Admin header
  |> beacon.with_middleware(middleware.only("/admin", require_admin()))
  // /api/*: adds version header
  |> beacon.with_middleware(middleware.only("/api", api_version()))
  // POST/PUT on /api: blocked (demo of method + path combo)
  |> beacon.with_middleware(
    middleware.only("/api", middleware.methods([http.Post, http.Put], block_writes())),
  )
  |> beacon.start(8080)
}
