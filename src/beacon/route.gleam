/// URL routing — pattern matching, parameter extraction, route tables.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Parsed route with extracted parameters.
pub type Route {
  Route(
    /// The original path string (e.g., "/blog/hello").
    path: String,
    /// Path segments (e.g., ["blog", "hello"]).
    segments: List(String),
    /// Extracted route parameters (e.g., {"slug": "hello"}).
    params: Dict(String, String),
    /// Query string parameters (e.g., {"page": "2"}).
    query: Dict(String, String),
  )
}

/// A registered route pattern (e.g., "/blog/:slug").
pub type RoutePattern {
  RoutePattern(
    /// The original pattern string.
    pattern: String,
    /// Pattern segments (e.g., ["blog", ":slug"]).
    segments: List(String),
  )
}

/// Parse a path string into segments.
/// "/blog/hello" → ["blog", "hello"]
/// "/" → []
pub fn parse_path(path: String) -> List(String) {
  path
  |> string.split("/")
  |> list.filter(fn(s) { s != "" })
}

/// Parse a route pattern string into a RoutePattern.
pub fn pattern(pat: String) -> RoutePattern {
  RoutePattern(pattern: pat, segments: parse_path(pat))
}

/// Parse query string into a dict.
/// "page=2&sort=date" → {"page": "2", "sort": "date"}
pub fn parse_query(query_string: String) -> Dict(String, String) {
  case query_string {
    "" -> dict.new()
    qs ->
      qs
      |> string.split("&")
      |> list.fold(dict.new(), fn(acc, pair) {
        case string.split(pair, "=") {
          [key, value] -> dict.insert(acc, key, value)
          [key] -> dict.insert(acc, key, "")
          _ -> acc
        }
      })
  }
}

/// Match a URL path against a list of route patterns.
/// Returns the first match with extracted parameters.
pub fn match_path(
  patterns: List(RoutePattern),
  path: String,
) -> Option(Route) {
  let #(path_part, query_part) = case string.split(path, "?") {
    [p, q] -> #(p, q)
    [p] -> #(p, "")
    _ -> #(path, "")
  }
  let segments = parse_path(path_part)
  let query = parse_query(query_part)

  list.find_map(patterns, fn(pat) {
    case match_segments(pat.segments, segments, dict.new()) {
      Some(params) ->
        Ok(Route(
          path: path_part,
          segments: segments,
          params: params,
          query: query,
        ))
      None -> Error(Nil)
    }
  })
  |> option.from_result
}

/// Match path segments against pattern segments, extracting parameters.
fn match_segments(
  pattern_segs: List(String),
  path_segs: List(String),
  params: Dict(String, String),
) -> Option(Dict(String, String)) {
  case pattern_segs, path_segs {
    // Both empty — match!
    [], [] -> Some(params)
    // Pattern has wildcard "*" — matches everything remaining
    ["*"], _ -> Some(params)
    // Dynamic segment ":param" — capture value
    [":" <> param_name, ..rest_pattern], [value, ..rest_path] ->
      match_segments(
        rest_pattern,
        rest_path,
        dict.insert(params, param_name, value),
      )
    // Static segment — must match exactly
    [pat, ..rest_pattern], [seg, ..rest_path] if pat == seg ->
      match_segments(rest_pattern, rest_path, params)
    // No match
    _, _ -> None
  }
}

/// Create a Route from a path string (no pattern matching, just parsing).
pub fn from_path(path: String) -> Route {
  let #(path_part, query_part) = case string.split(path, "?") {
    [p, q] -> #(p, q)
    [p] -> #(p, "")
    _ -> #(path, "")
  }
  Route(
    path: path_part,
    segments: parse_path(path_part),
    params: dict.new(),
    query: parse_query(query_part),
  )
}

/// Get a route parameter by name.
pub fn param(route: Route, name: String) -> Result(String, Nil) {
  dict.get(route.params, name)
}

/// Route guard — a function that decides if navigation is allowed.
/// Returns Ok(Nil) to allow, Error(redirect_path) to redirect.
pub type RouteGuard =
  fn(Route) -> Result(Nil, String)

/// A route with an optional layout and guard.
pub type RouteDefinition {
  RouteDefinition(
    /// URL pattern (e.g., "/blog/:slug").
    pattern: RoutePattern,
    /// Optional layout name (for nested routes sharing a layout).
    layout: option.Option(String),
    /// Optional guard (e.g., require auth).
    guard: option.Option(RouteGuard),
  )
}

/// Create a route definition with a layout.
pub fn with_layout(pat: String, layout: String) -> RouteDefinition {
  RouteDefinition(
    pattern: pattern(pat),
    layout: option.Some(layout),
    guard: option.None,
  )
}

/// Create a guarded route definition.
pub fn guarded(pat: String, guard: RouteGuard) -> RouteDefinition {
  RouteDefinition(
    pattern: pattern(pat),
    layout: option.None,
    guard: option.Some(guard),
  )
}

/// Create a guarded route with a layout.
pub fn guarded_with_layout(
  pat: String,
  layout: String,
  guard: RouteGuard,
) -> RouteDefinition {
  RouteDefinition(
    pattern: pattern(pat),
    layout: option.Some(layout),
    guard: option.Some(guard),
  )
}

/// Match a path against route definitions, checking guards.
/// Returns Ok(#(Route, layout)) if allowed, Error(redirect_path) if guard rejects.
pub fn match_guarded(
  defs: List(RouteDefinition),
  path: String,
) -> Result(#(Route, option.Option(String)), String) {
  let #(path_part, query_part) = case string.split(path, "?") {
    [p, q] -> #(p, q)
    [p] -> #(p, "")
    _ -> #(path, "")
  }
  let segments = parse_path(path_part)
  let query = parse_query(query_part)

  match_guarded_loop(defs, segments, path_part, query)
}

fn match_guarded_loop(
  defs: List(RouteDefinition),
  segments: List(String),
  path_part: String,
  query: dict.Dict(String, String),
) -> Result(#(Route, option.Option(String)), String) {
  case defs {
    [] -> Error("not_found")
    [def, ..rest] -> {
      case match_segments(def.pattern.segments, segments, dict.new()) {
        option.Some(params) -> {
          let matched_route = Route(
            path: path_part,
            segments: segments,
            params: params,
            query: query,
          )
          case def.guard {
            option.Some(guard_fn) -> {
              case guard_fn(matched_route) {
                Ok(Nil) -> Ok(#(matched_route, def.layout))
                Error(redirect) -> Error(redirect)
              }
            }
            option.None -> Ok(#(matched_route, def.layout))
          }
        }
        option.None -> match_guarded_loop(rest, segments, path_part, query)
      }
    }
  }
}

/// Check if a path matches any route (returns False for 404).
pub fn is_valid_path(
  patterns: List(RoutePattern),
  path: String,
) -> Bool {
  case match_path(patterns, path) {
    option.Some(_) -> True
    option.None -> False
  }
}

/// Get a query parameter by name.
pub fn query_param(route: Route, name: String) -> Result(String, Nil) {
  dict.get(route.query, name)
}
