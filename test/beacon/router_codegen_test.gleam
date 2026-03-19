import beacon/router/codegen
import beacon/router/scanner
import gleam/list
import simplifile

// --- Constructor name tests ---

pub fn constructor_name_index_test() {
  let route = make_route([], "index")
  let assert "Index" = codegen.route_constructor_name(route)
}

pub fn constructor_name_simple_test() {
  let route = make_route(["about"], "about")
  let assert "About" = codegen.route_constructor_name(route)
}

pub fn constructor_name_nested_test() {
  let route = make_route(["blog", "posts"], "blog/posts")
  let assert "BlogPosts" = codegen.route_constructor_name(route)
}

pub fn constructor_name_dynamic_test() {
  let route = make_route(["blog", ":slug"], "blog/[slug]")
  let assert "BlogSlug" = codegen.route_constructor_name(route)
}

pub fn constructor_name_multiple_dynamic_test() {
  let route =
    make_route(["users", ":id", "posts", ":post_id"], "users/[id]/posts/[post_id]")
  let assert "UsersIdPostsPostId" = codegen.route_constructor_name(route)
}

// --- Route params tests ---

pub fn route_params_no_dynamic_test() {
  let route = make_route(["about"], "about")
  let assert [] = codegen.route_params(route)
}

pub fn route_params_one_dynamic_test() {
  let route = make_route(["blog", ":slug"], "blog/[slug]")
  let assert ["slug"] = codegen.route_params(route)
}

pub fn route_params_multiple_dynamic_test() {
  let route =
    make_route(["users", ":id", "posts", ":post_id"], "users/[id]/posts/[post_id]")
  let assert ["id", "post_id"] = codegen.route_params(route)
}

// --- Code generation tests ---

pub fn generate_code_empty_routes_test() {
  let code = codegen.generate_code([])
  let assert True = str_contains(code, "AUTO-GENERATED")
  let assert True = str_contains(code, "pub type Route")
  let assert True = str_contains(code, "NotFound")
  let assert True = str_contains(code, "pub fn match_route")
  let assert True = str_contains(code, "pub fn to_path")
}

pub fn generate_code_index_route_test() {
  let routes = [make_route([], "index")]
  let code = codegen.generate_code(routes)
  let assert True = str_contains(code, "Index")
  let assert True = str_contains(code, "[] -> Ok(Index)")
  let assert True = str_contains(code, "Index -> \"/\"")
}

pub fn generate_code_static_route_test() {
  let routes = [make_route(["about"], "about")]
  let code = codegen.generate_code(routes)
  let assert True = str_contains(code, "About")
  let assert True = str_contains(code, "[\"about\"] -> Ok(About)")
}

pub fn generate_code_dynamic_route_test() {
  let routes = [make_route(["blog", ":slug"], "blog/[slug]")]
  let code = codegen.generate_code(routes)
  let assert True = str_contains(code, "BlogSlug(slug: String)")
  let assert True = str_contains(code, "[\"blog\", slug] -> Ok(BlogSlug(slug: slug))")
}

pub fn generate_code_multiple_routes_test() {
  let routes = [
    make_route([], "index"),
    make_route(["about"], "about"),
    make_route(["blog", ":slug"], "blog/[slug]"),
  ]
  let code = codegen.generate_code(routes)
  let assert True = str_contains(code, "Index")
  let assert True = str_contains(code, "About")
  let assert True = str_contains(code, "BlogSlug")
}

pub fn generate_code_to_path_static_test() {
  let routes = [make_route(["about"], "about")]
  let code = codegen.generate_code(routes)
  let assert True = str_contains(code, "About -> \"/\" <> \"about\"")
}

pub fn generate_code_to_path_dynamic_test() {
  let routes = [make_route(["blog", ":slug"], "blog/[slug]")]
  let code = codegen.generate_code(routes)
  let assert True = str_contains(code, "BlogSlug(slug) -> \"/\" <> \"blog\" <> \"/\" <> slug")
}

// --- Check mode tests ---

pub fn check_passes_when_up_to_date_test() {
  let test_dir = "/tmp/beacon_test_check_" <> unique_id()
  let routes_dir = test_dir <> "/routes"
  let output_path = test_dir <> "/generated/routes.gleam"

  // Create route file
  let assert Ok(Nil) = simplifile.create_directory_all(routes_dir)
  let assert Ok(Nil) = simplifile.create_directory_all(test_dir <> "/generated")
  let assert Ok(Nil) =
    simplifile.write(routes_dir <> "/index.gleam", "pub fn view() { Nil }\n")

  // Generate routes
  let assert Ok(routes) = scanner.scan_routes(routes_dir)
  let assert Ok(Nil) = codegen.generate(routes, output_path)

  // Check should pass (run_check doesn't halt in test since the files match)
  codegen.run_check(routes_dir, output_path)

  // Cleanup
  let assert Ok(Nil) = simplifile.delete(test_dir)
}

fn unique_id() -> String {
  do_unique_id()
}

@external(erlang, "beacon_test_ffi", "unique_ref")
fn do_unique_id() -> String

// --- Helpers ---

fn make_route(
  segments: List(String),
  module_name: String,
) -> scanner.RouteDefinition {
  scanner.RouteDefinition(
    path_segments: segments,
    module_name: module_name,
    file_path: "src/routes/" <> module_name <> ".gleam",
    has_loader: False,
    has_action: False,
    has_view: True,
    has_init: True,
    has_update: True,
    has_model: True,
    has_msg: True,
    has_local: False,
    init_takes_params: False,
    has_guard: False,
    has_on_update: False,
  )
}

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool

// --- Scanner tests for new fields ---

pub fn scanner_detects_init_test() {
  let test_dir = "/tmp/beacon_test_scanner_init_" <> unique_id()
  let routes_dir = test_dir <> "/routes"
  let assert Ok(Nil) = simplifile.create_directory_all(routes_dir)
  let assert Ok(Nil) =
    simplifile.write(
      routes_dir <> "/index.gleam",
      "pub type Model { Model }
pub type Msg { NoOp }
pub fn init() -> Model { Model }
pub fn update(model, _msg) { model }
pub fn view(_model) { Nil }
",
    )
  let assert Ok(routes) = scanner.scan_routes(routes_dir)
  let assert [route] = routes
  let assert True = route.has_init
  let assert True = route.has_update
  let assert True = route.has_view
  let assert True = route.has_model
  let assert True = route.has_msg
  let assert False = route.has_local
  let assert False = route.init_takes_params
  let assert Ok(Nil) = simplifile.delete(test_dir)
}

pub fn scanner_detects_init_with_params_test() {
  let test_dir = "/tmp/beacon_test_scanner_params_" <> unique_id()
  let routes_dir = test_dir <> "/routes"
  let assert Ok(Nil) = simplifile.create_directory_all(routes_dir)
  let assert Ok(Nil) =
    simplifile.write(
      routes_dir <> "/index.gleam",
      "pub type Model { Model(slug: String) }
pub type Msg { NoOp }
pub fn init(params) -> Model { Model(slug: \"\") }
pub fn update(model, _msg) { model }
pub fn view(_model) { Nil }
",
    )
  let assert Ok(routes) = scanner.scan_routes(routes_dir)
  let assert [route] = routes
  let assert True = route.init_takes_params
  let assert Ok(Nil) = simplifile.delete(test_dir)
}

pub fn scanner_detects_local_type_test() {
  let test_dir = "/tmp/beacon_test_scanner_local_" <> unique_id()
  let routes_dir = test_dir <> "/routes"
  let assert Ok(Nil) = simplifile.create_directory_all(routes_dir)
  let assert Ok(Nil) =
    simplifile.write(
      routes_dir <> "/index.gleam",
      "pub type Model { Model }
pub type Local { Local(editing: Bool) }
pub type Msg { NoOp }
pub fn init() { Model }
pub fn update(model, _msg) { model }
pub fn view(_model) { Nil }
",
    )
  let assert Ok(routes) = scanner.scan_routes(routes_dir)
  let assert [route] = routes
  let assert True = route.has_local
  let assert Ok(Nil) = simplifile.delete(test_dir)
}

pub fn scanner_bracket_dynamic_segment_test() {
  let assert "about" = scanner.parse_segment("about")
  let assert ":id" = scanner.parse_segment("[id]")
  let assert ":slug" = scanner.parse_segment("[slug]")
  let assert ":post_id" = scanner.parse_segment("[post_id]")
}

pub fn scanner_detects_guard_test() {
  let test_dir = "/tmp/beacon_test_scanner_guard_" <> unique_id()
  let routes_dir = test_dir <> "/routes"
  let assert Ok(Nil) = simplifile.create_directory_all(routes_dir)
  let assert Ok(Nil) =
    simplifile.write(
      routes_dir <> "/admin.gleam",
      "pub type Model { Model }
pub type Msg { NoOp }
pub fn init() { Model }
pub fn update(model, _msg) { model }
pub fn view(_model) { Nil }
pub fn guard(_route) { Ok(Nil) }
",
    )
  let assert Ok(routes) = scanner.scan_routes(routes_dir)
  let assert [route] = routes
  let assert True = route.has_guard
  let assert Ok(Nil) = simplifile.delete(test_dir)
}

// --- Dispatcher code generation tests ---

pub fn dispatcher_generates_imports_test() {
  let routes = [
    make_route([], "index"),
    make_route(["about"], "about"),
  ]
  let code = codegen.generate_dispatcher_code(routes)
  let assert True = str_contains(code, "import routes/index as route_index")
  let assert True = str_contains(code, "import routes/about as route_about")
  let assert True = str_contains(code, "import beacon/runtime")
  let assert True = str_contains(code, "import beacon/effect")
}

pub fn dispatcher_generates_start_for_route_test() {
  let routes = [
    make_route([], "index"),
    make_route(["about"], "about"),
  ]
  let code = codegen.generate_dispatcher_code(routes)
  let assert True = str_contains(code, "pub fn start_for_route(")
  let assert True = str_contains(code, "[] -> {")
  let assert True = str_contains(code, "[\"about\"] -> {")
  let assert True = str_contains(code, "runtime.start_and_connect(")
}

pub fn dispatcher_generates_dynamic_params_test() {
  let routes = [
    make_route_with_params(["users", ":id"], "users/[id]", True),
  ]
  let code = codegen.generate_dispatcher_code(routes)
  let assert True = str_contains(code, "[\"users\", id] -> {")
  let assert True = str_contains(code, "dict.from_list([#(\"id\", id)])")
  let assert True = str_contains(code, "route_users_id.init(params)")
}

pub fn dispatcher_generates_ssr_for_route_test() {
  let routes = [
    make_route([], "index"),
  ]
  let code = codegen.generate_dispatcher_code(routes)
  let assert True = str_contains(code, "pub fn ssr_for_route(")
  let assert True = str_contains(code, "ssr.render_page(")
  let assert True = str_contains(code, "route_index.init()")
  let assert True = str_contains(code, "route_index.view")
}

pub fn dispatcher_generates_not_found_arm_test() {
  let routes = [make_route([], "index")]
  let code = codegen.generate_dispatcher_code(routes)
  let assert True = str_contains(code, "_ -> Error(error.RouterError")
  let assert True = str_contains(code, "404")
}

pub fn scanner_and_dispatcher_integration_test() {
  // Create temp route files
  let test_dir = "/tmp/beacon_test_dispatcher_" <> unique_id()
  let routes_dir = test_dir <> "/routes"
  let assert Ok(Nil) = simplifile.create_directory_all(routes_dir)
  let assert Ok(Nil) =
    simplifile.write(
      routes_dir <> "/index.gleam",
      "pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn init() -> Model { Model(count: 0) }
pub fn update(model, _msg) { model }
pub fn view(_model) { Nil }
",
    )
  let assert Ok(Nil) =
    simplifile.write(
      routes_dir <> "/about.gleam",
      "pub type Model { Model }
pub type Msg { NoOp }
pub fn init() -> Model { Model }
pub fn update(model, _msg) { model }
pub fn view(_model) { Nil }
",
    )
  let assert Ok(Nil) =
    simplifile.write(
      routes_dir <> "/settings.gleam",
      "pub type Model { Model(name: String) }
pub type Msg { NoOp }
pub fn init() -> Model { Model(name: \"\") }
pub fn update(model, _msg) { model }
pub fn view(_model) { Nil }
",
    )

  // Scan routes
  let assert Ok(routes) = scanner.scan_routes(routes_dir)
  let assert 3 = list.length(routes)

  // Generate dispatcher code
  let code = codegen.generate_dispatcher_code(routes)

  // Verify imports
  let assert True = str_contains(code, "import routes/index as route_index")
  let assert True = str_contains(code, "import routes/about as route_about")
  let assert True = str_contains(code, "import routes/settings as route_settings")

  // Verify start_for_route
  let assert True = str_contains(code, "pub fn start_for_route(")
  let assert True = str_contains(code, "[] -> {")
  let assert True = str_contains(code, "route_index.init()")
  let assert True = str_contains(code, "[\"about\"] -> {")
  let assert True = str_contains(code, "route_about.init()")
  let assert True = str_contains(code, "[\"settings\"] -> {")
  let assert True = str_contains(code, "route_settings.init()")

  // Verify ssr_for_route
  let assert True = str_contains(code, "pub fn ssr_for_route(")

  // Verify 404 handling
  let assert True = str_contains(code, "_ -> Error(error.RouterError")

  // Verify routes have expected fields
  let assert Ok(index_route) =
    list.find(routes, fn(r: scanner.RouteDefinition) {
      r.module_name == "index"
    })
  let assert False = index_route.init_takes_params
  let assert True = index_route.has_init
  let assert True = index_route.has_update
  let assert True = index_route.has_view
  let assert True = index_route.has_model
  let assert True = index_route.has_msg

  // Cleanup
  let assert Ok(Nil) = simplifile.delete(test_dir)
}

fn make_route_with_params(
  segments: List(String),
  module_name: String,
  takes_params: Bool,
) -> scanner.RouteDefinition {
  scanner.RouteDefinition(
    path_segments: segments,
    module_name: module_name,
    file_path: "src/routes/" <> module_name <> ".gleam",
    has_loader: False,
    has_action: False,
    has_view: True,
    has_init: True,
    has_update: True,
    has_model: True,
    has_msg: True,
    has_local: False,
    init_takes_params: takes_params,
    has_guard: False,
    has_on_update: False,
  )
}
