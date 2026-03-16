import beacon/route
import gleam/dict
import gleam/option.{None, Some}

pub fn parse_path_root_test() {
  let assert [] = route.parse_path("/")
}

pub fn parse_path_segments_test() {
  let assert ["blog", "hello"] = route.parse_path("/blog/hello")
}

pub fn parse_query_test() {
  let q = route.parse_query("page=2&sort=date")
  let assert Ok("2") = dict.get(q, "page")
  let assert Ok("date") = dict.get(q, "sort")
}

pub fn parse_query_empty_test() {
  let q = route.parse_query("")
  let assert 0 = dict.size(q)
}

pub fn match_exact_root_test() {
  let patterns = [route.pattern("/")]
  let assert Some(r) = route.match_path(patterns, "/")
  let assert [] = r.segments
}

pub fn match_exact_path_test() {
  let patterns = [route.pattern("/about"), route.pattern("/blog")]
  let assert Some(r) = route.match_path(patterns, "/blog")
  let assert ["blog"] = r.segments
}

pub fn match_dynamic_param_test() {
  let patterns = [route.pattern("/blog/:slug")]
  let assert Some(r) = route.match_path(patterns, "/blog/hello-world")
  let assert Ok("hello-world") = route.param(r, "slug")
}

pub fn match_multiple_params_test() {
  let patterns = [route.pattern("/users/:id/posts/:post_id")]
  let assert Some(r) = route.match_path(patterns, "/users/42/posts/7")
  let assert Ok("42") = route.param(r, "id")
  let assert Ok("7") = route.param(r, "post_id")
}

pub fn match_no_match_test() {
  let patterns = [route.pattern("/about")]
  let assert None = route.match_path(patterns, "/blog")
}

pub fn match_with_query_test() {
  let patterns = [route.pattern("/search")]
  let assert Some(r) = route.match_path(patterns, "/search?q=gleam&page=1")
  let assert Ok("gleam") = route.query_param(r, "q")
  let assert Ok("1") = route.query_param(r, "page")
}

pub fn match_wildcard_test() {
  let patterns = [route.pattern("/api/*")]
  let assert Some(_) = route.match_path(patterns, "/api/users/123")
}

pub fn match_first_wins_test() {
  let patterns = [route.pattern("/blog"), route.pattern("/blog/:slug")]
  let assert Some(r) = route.match_path(patterns, "/blog")
  let assert 0 = dict.size(r.params)
}

pub fn guarded_route_allows_test() {
  let defs = [
    route.guarded("/admin", fn(_route) { Ok(Nil) }),
  ]
  let assert Ok(#(_route, _layout)) = route.match_guarded(defs, "/admin")
}

pub fn guarded_route_rejects_test() {
  let defs = [
    route.guarded("/admin", fn(_route) { Error("/login") }),
  ]
  let assert Error("/login") = route.match_guarded(defs, "/admin")
}

pub fn route_with_layout_test() {
  let defs = [
    route.with_layout("/dashboard", "app"),
    route.with_layout("/settings", "app"),
  ]
  let assert Ok(#(_route, Some("app"))) = route.match_guarded(defs, "/dashboard")
}

pub fn guarded_with_layout_test() {
  let defs = [
    route.guarded_with_layout("/profile", "app", fn(_route) { Ok(Nil) }),
  ]
  let assert Ok(#(_route, Some("app"))) = route.match_guarded(defs, "/profile")
}

pub fn not_found_test() {
  let defs = [
    route.with_layout("/", "main"),
  ]
  let assert Error("not_found") = route.match_guarded(defs, "/nonexistent")
}

pub fn is_valid_path_test() {
  let patterns = [route.pattern("/"), route.pattern("/about")]
  let assert True = route.is_valid_path(patterns, "/about")
  let assert False = route.is_valid_path(patterns, "/nope")
}

pub fn from_path_test() {
  let r = route.from_path("/blog/hello?page=2")
  let assert "/blog/hello" = r.path
  let assert ["blog", "hello"] = r.segments
  let assert Ok("2") = route.query_param(r, "page")
}
