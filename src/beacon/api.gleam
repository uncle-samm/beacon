/// Typed HTTP API route helpers.
///
/// These helpers build the handler accepted by `beacon.api_routes` while keeping
/// raw request/response access available inside each route.
import beacon/transport/server.{type Connection, type ResponseBody, Bytes}
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A single API route declaration.
///
/// Construct with `get`, `post`, `put`, `patch`, or `delete`, then pass the list
/// to `routes`.
pub opaque type Route {
  Route(
    method: http.Method,
    segments: List(String),
    handler: fn(Request(Connection)) -> Response(ResponseBody),
  )
}

/// Declare a GET route.
pub fn get(
  path: String,
  handler: fn(Request(Connection)) -> Response(ResponseBody),
) -> Route {
  Route(method: http.Get, segments: path_segments(path), handler: handler)
}

/// Declare a POST route.
pub fn post(
  path: String,
  handler: fn(Request(Connection)) -> Response(ResponseBody),
) -> Route {
  Route(method: http.Post, segments: path_segments(path), handler: handler)
}

/// Declare a PUT route.
pub fn put(
  path: String,
  handler: fn(Request(Connection)) -> Response(ResponseBody),
) -> Route {
  Route(method: http.Put, segments: path_segments(path), handler: handler)
}

/// Declare a PATCH route.
pub fn patch(
  path: String,
  handler: fn(Request(Connection)) -> Response(ResponseBody),
) -> Route {
  Route(method: http.Patch, segments: path_segments(path), handler: handler)
}

/// Declare a DELETE route.
pub fn delete(
  path: String,
  handler: fn(Request(Connection)) -> Response(ResponseBody),
) -> Route {
  Route(method: http.Delete, segments: path_segments(path), handler: handler)
}

/// Build the handler expected by `beacon.api_routes`.
///
/// Routes are matched in declaration order. Unknown method/path combinations
/// return `None`, so Beacon continues to SSR/static routing.
pub fn routes(
  route_list: List(Route),
) -> fn(Request(Connection)) -> Option(Response(ResponseBody)) {
  fn(req: Request(Connection)) { dispatch(route_list, req) }
}

/// Create a JSON response.
pub fn json(status: Int, body: String) -> Response(ResponseBody) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(Bytes(bytes_tree.from_string(body)))
}

/// Create a text response.
pub fn text(status: Int, body: String) -> Response(ResponseBody) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(Bytes(bytes_tree.from_string(body)))
}

/// Create an empty response.
pub fn empty(status: Int) -> Response(ResponseBody) {
  response.new(status)
  |> response.set_body(Bytes(bytes_tree.new()))
}

fn dispatch(
  route_list: List(Route),
  req: Request(Connection),
) -> Option(Response(ResponseBody)) {
  case route_list {
    [] -> None
    [Route(method, segments, handler), ..rest] -> {
      case req.method == method && request.path_segments(req) == segments {
        True -> Some(handler(req))
        False -> dispatch(rest, req)
      }
    }
  }
}

fn path_segments(path: String) -> List(String) {
  let path_only = case string.split(path, "?") {
    [path, ..] -> path
    [] -> path
  }

  path_only
  |> string.split("/")
  |> list.filter(fn(segment) { segment != "" })
}
