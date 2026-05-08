/// URL routing — pattern matching, parameter extraction, route tables.
import beacon/element.{type Node}
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

/// Explicit route page declaration.
///
/// A page declares the URL pattern, the message to send when that page is
/// entered during SSR or client-side navigation, and the typed render function
/// for that page. Route modules can export page constructors and the app can
/// import them explicitly; Beacon does not discover files.
pub opaque type Page(model, msg) {
  Page(
    pattern: RoutePattern,
    on_enter: fn(Route) -> msg,
    render: fn(model, Route) -> Node(msg),
  )
}

/// Declare a page route.
///
/// ```gleam
/// route.page(
///   "/projects/:id",
///   fn(r) { RouteChanged(r.path) },
///   fn(model, route) { project_view(model, route) },
/// )
/// ```
pub fn page(
  pattern pattern_string: String,
  on_enter on_enter: fn(Route) -> msg,
  render render: fn(model, Route) -> Node(msg),
) -> Page(model, msg) {
  Page(pattern: pattern(pattern_string), on_enter: on_enter, render: render)
}

/// Declare a page route backed by a child model selected from the root model.
///
/// This is the route mini-app building block. A route module can own its own
/// `Model`, `Msg`, `update`, and `view`; the root app embeds that child model,
/// wraps child messages into the root `Msg`, and stays on the single Beacon app
/// runtime.
pub fn page_model(
  pattern pattern_string: String,
  on_enter on_enter: fn(Route) -> msg,
  select select: fn(root_model) -> child_model,
  render render: fn(child_model, Route) -> Node(msg),
) -> Page(root_model, msg) {
  page(pattern_string, on_enter, fn(root_model, resolved) {
    render(select(root_model), resolved)
  })
}

/// Update a child route model embedded in the root model.
///
/// The parent still decides which child messages are accepted. This helper only
/// removes the repetitive select-update-replace boilerplate for route mini-apps.
pub fn update_model(
  root_model: root_model,
  child_msg: child_msg,
  select: fn(root_model) -> child_model,
  replace: fn(root_model, child_model) -> root_model,
  update: fn(child_model, child_msg) -> child_model,
) -> root_model {
  let child_model = select(root_model)
  let updated_child = update(child_model, child_msg)
  replace(root_model, updated_child)
}

/// Update a child route model and child route server state embedded in root
/// app state.
///
/// The child `Server` value stays private because it is selected only from the
/// root server state. It is never passed to route rendering or client bundle
/// generation.
pub fn update_server_model(
  root_model: root_model,
  root_server: root_server,
  child_msg: child_msg,
  select_model: fn(root_model) -> child_model,
  replace_model: fn(root_model, child_model) -> root_model,
  select_server: fn(root_server) -> child_server,
  replace_server: fn(root_server, child_server) -> root_server,
  update: fn(child_model, child_server, child_msg) ->
    #(child_model, child_server),
) -> #(root_model, root_server) {
  let child_model = select_model(root_model)
  let child_server = select_server(root_server)
  let #(updated_child, updated_server) =
    update(child_model, child_server, child_msg)
  #(
    replace_model(root_model, updated_child),
    replace_server(root_server, updated_server),
  )
}

/// Get the pattern for a page route.
pub fn page_pattern(page: Page(model, msg)) -> RoutePattern {
  page.pattern
}

/// Extract all route patterns from an explicit page manifest.
pub fn page_patterns(pages: List(Page(model, msg))) -> List(RoutePattern) {
  list.map(pages, page_pattern)
}

/// Dispatch a matched route to the first matching page declaration.
///
/// This returns `Error` only when the route did not come from the same page
/// manifest. `beacon.route_pages` treats that as a programming error and fails
/// loudly.
pub fn dispatch_page(
  pages: List(Page(model, msg)),
  resolved: Route,
) -> Result(msg, String) {
  case pages {
    [] -> Error("No explicit route page matched " <> resolved.path)
    [Page(pattern: pattern, on_enter: on_enter, ..), ..rest] -> {
      case match_path([pattern], resolved.path) {
        Some(route) -> Ok(on_enter(route))
        None -> dispatch_page(rest, resolved)
      }
    }
  }
}

/// Dispatch a model to the first matching page render function.
///
/// This is the typed root route dispatcher for explicit route manifests. The
/// app still owns its `Model` and `Msg`, but the page list is now the single
/// source for accepted patterns, enter messages, and view dispatch.
pub fn dispatch_view(
  pages: List(Page(model, msg)),
  model: model,
  path: String,
) -> Result(Node(msg), String) {
  case pages {
    [] -> Error("No explicit route page view matched " <> path)
    [Page(pattern: pattern, render: render, ..), ..rest] -> {
      case match_path([pattern], path) {
        Some(route) -> Ok(render(model, route))
        None -> dispatch_view(rest, model, path)
      }
    }
  }
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
pub fn match_path(patterns: List(RoutePattern), path: String) -> Option(Route) {
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
          let matched_route =
            Route(
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
pub fn is_valid_path(patterns: List(RoutePattern), path: String) -> Bool {
  case match_path(patterns, path) {
    option.Some(_) -> True
    option.None -> False
  }
}

/// Get a query parameter by name.
pub fn query_param(route: Route, name: String) -> Result(String, Nil) {
  dict.get(route.query, name)
}
