import beacon/router/codegen
import beacon/router/scanner
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
  )
}

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool
