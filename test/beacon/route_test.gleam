import beacon/element
import beacon/html
import beacon/route
import gleam/dict
import gleam/int
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
  let assert Ok(#(_route, Some("app"))) =
    route.match_guarded(defs, "/dashboard")
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

pub type TestRouteMsg {
  Entered(String, String)
}

pub type TestRouteModel {
  TestRouteModel(label: String, child: TestChildModel)
}

pub type TestChildModel {
  TestChildModel(count: Int)
}

pub type TestRouteServer {
  TestRouteServer(child: TestChildServer, audit: Int)
}

pub type TestChildServer {
  TestChildServer(secret: String, writes: Int)
}

pub type TestChildMsg {
  ChildIncrement
}

pub type TestLocal {
  TestLocal(child: TestChildModel)
}

fn test_model() -> TestRouteModel {
  TestRouteModel(label: "typed", child: TestChildModel(count: 41))
}

pub fn page_manifest_extracts_patterns_test() {
  let pages = [
    route.page(
      "/",
      fn(r) { Entered(r.path, "") },
      fn(_model: TestRouteModel, _route) { html.text("root") },
    ),
    route.page(
      "/projects/:id",
      fn(r) {
        let assert Ok(id) = route.param(r, "id")
        Entered(r.path, id)
      },
      fn(_model: TestRouteModel, route) {
        let assert Ok(id) = route.param(route, "id")
        html.text("project " <> id)
      },
    ),
  ]
  let patterns = route.page_patterns(pages)
  let assert Some(root) = route.match_path(patterns, "/")
  let assert "/" = root.path
  let assert Some(project) = route.match_path(patterns, "/projects/42")
  let assert Ok("42") = route.param(project, "id")
}

pub fn page_manifest_dispatches_matching_page_test() {
  let pages = [
    route.page(
      "/",
      fn(r) { Entered(r.path, "root") },
      fn(_model: TestRouteModel, _route) { html.text("root") },
    ),
    route.page(
      "/projects/:id",
      fn(r) {
        let assert Ok(id) = route.param(r, "id")
        Entered(r.path, id)
      },
      fn(_model: TestRouteModel, route) {
        let assert Ok(id) = route.param(route, "id")
        html.text("project " <> id)
      },
    ),
  ]
  let assert Some(project) =
    route.match_path(route.page_patterns(pages), "/projects/42")
  let assert Ok(Entered("/projects/42", "42")) =
    route.dispatch_page(pages, project)
}

pub fn page_manifest_dispatch_rejects_unknown_route_test() {
  let pages = [
    route.page(
      "/",
      fn(r) { Entered(r.path, "root") },
      fn(_model: TestRouteModel, _route) { html.text("root") },
    ),
  ]
  let unknown = route.from_path("/missing")
  let assert Error(reason) = route.dispatch_page(pages, unknown)
  let assert "No explicit route page matched /missing" = reason
}

pub fn page_manifest_dispatches_typed_view_test() {
  let pages = [
    route.page(
      "/",
      fn(r) { Entered(r.path, "root") },
      fn(model: TestRouteModel, _route) { html.text(model.label <> " root") },
    ),
    route.page(
      "/projects/:id",
      fn(r) {
        let assert Ok(id) = route.param(r, "id")
        Entered(r.path, id)
      },
      fn(model: TestRouteModel, route) {
        let assert Ok(id) = route.param(route, "id")
        html.text(model.label <> " project " <> id)
      },
    ),
  ]
  let assert Ok(node) = route.dispatch_view(pages, test_model(), "/projects/42")
  let assert "typed project 42" = element.to_string(node)
}

pub fn page_manifest_view_rejects_unknown_route_test() {
  let pages = [
    route.page(
      "/",
      fn(r) { Entered(r.path, "root") },
      fn(model: TestRouteModel, _route) { html.text(model.label) },
    ),
  ]
  let assert Error(reason) =
    route.dispatch_view(pages, test_model(), "/missing")
  let assert "No explicit route page view matched /missing" = reason
}

pub fn page_model_dispatches_selected_route_model_test() {
  let pages = [
    route.page_model(
      "/child/:id",
      fn(r) {
        let assert Ok(id) = route.param(r, "id")
        Entered(r.path, id)
      },
      fn(model: TestRouteModel) { model.child },
      fn(child: TestChildModel, resolved) {
        let assert Ok(id) = route.param(resolved, "id")
        html.text("child " <> id <> " count " <> int.to_string(child.count))
      },
    ),
  ]
  let assert Ok(node) = route.dispatch_view(pages, test_model(), "/child/7")
  let assert "child 7 count 41" = element.to_string(node)
}

pub fn update_model_updates_embedded_route_model_test() {
  let updated =
    route.update_model(
      test_model(),
      ChildIncrement,
      fn(model: TestRouteModel) { model.child },
      fn(model: TestRouteModel, child: TestChildModel) {
        TestRouteModel(..model, child: child)
      },
      fn(child: TestChildModel, msg: TestChildMsg) {
        case msg {
          ChildIncrement -> TestChildModel(count: child.count + 1)
        }
      },
    )
  let assert 42 = updated.child.count
  let assert "typed" = updated.label
}

pub fn update_server_model_updates_embedded_route_model_and_server_test() {
  let server =
    TestRouteServer(
      child: TestChildServer(secret: "private-route-secret", writes: 2),
      audit: 9,
    )
  let #(updated_model, updated_server) =
    route.update_server_model(
      test_model(),
      server,
      ChildIncrement,
      fn(model: TestRouteModel) { model.child },
      fn(model: TestRouteModel, child: TestChildModel) {
        TestRouteModel(..model, child: child)
      },
      fn(server: TestRouteServer) { server.child },
      fn(server: TestRouteServer, child: TestChildServer) {
        TestRouteServer(..server, child: child)
      },
      fn(child: TestChildModel, server: TestChildServer, msg: TestChildMsg) {
        case msg {
          ChildIncrement -> #(
            TestChildModel(count: child.count + 1),
            TestChildServer(..server, writes: server.writes + 1),
          )
        }
      },
    )

  let assert 42 = updated_model.child.count
  let assert "typed" = updated_model.label
  let assert "private-route-secret" = updated_server.child.secret
  let assert 3 = updated_server.child.writes
  let assert 9 = updated_server.audit
}

pub fn page_model_can_select_route_local_state_from_local_tuple_test() {
  let pages = [
    route.page_model(
      "/local",
      fn(r) { Entered(r.path, "local") },
      fn(state: #(TestRouteModel, TestLocal)) {
        let #(_model, local) = state
        local.child
      },
      fn(child: TestChildModel, _route) {
        html.text("local child " <> int.to_string(child.count))
      },
    ),
  ]
  let state = #(test_model(), TestLocal(child: TestChildModel(count: 5)))
  let assert Ok(node) = route.dispatch_view(pages, state, "/local")
  let assert "local child 5" = element.to_string(node)
}
