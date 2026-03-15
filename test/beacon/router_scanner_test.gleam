import beacon/router/scanner
import glance
import gleam/list
import simplifile

// --- Path segment parsing tests ---

pub fn index_file_produces_empty_segments_test() {
  let segments = scanner.file_path_to_segments("src/routes/index.gleam", "src/routes")
  let assert [] = segments
}

pub fn simple_file_produces_one_segment_test() {
  let segments = scanner.file_path_to_segments("src/routes/about.gleam", "src/routes")
  let assert ["about"] = segments
}

pub fn nested_file_produces_multiple_segments_test() {
  let segments =
    scanner.file_path_to_segments("src/routes/blog/posts.gleam", "src/routes")
  let assert ["blog", "posts"] = segments
}

pub fn nested_index_file_test() {
  let segments =
    scanner.file_path_to_segments("src/routes/blog/index.gleam", "src/routes")
  let assert ["blog"] = segments
}

pub fn dynamic_segment_test() {
  let segments =
    scanner.file_path_to_segments("src/routes/blog/[slug].gleam", "src/routes")
  let assert ["blog", ":slug"] = segments
}

pub fn multiple_dynamic_segments_test() {
  let segments =
    scanner.file_path_to_segments(
      "src/routes/users/[id]/posts/[post_id].gleam",
      "src/routes",
    )
  let assert ["users", ":id", "posts", ":post_id"] = segments
}

pub fn parse_segment_static_test() {
  let assert "about" = scanner.parse_segment("about")
}

pub fn parse_segment_dynamic_test() {
  let assert ":slug" = scanner.parse_segment("[slug]")
}

pub fn parse_segment_not_dynamic_test() {
  let assert "[incomplete" = scanner.parse_segment("[incomplete")
}

pub fn file_path_to_module_name_test() {
  let result =
    scanner.file_path_to_module_name("src/routes/blog/[slug].gleam", "src/routes")
  let assert "blog/[slug]" = result
}

pub fn file_path_to_module_name_index_test() {
  let result =
    scanner.file_path_to_module_name("src/routes/index.gleam", "src/routes")
  let assert "index" = result
}

// --- AST scanning tests ---

pub fn extract_public_functions_test() {
  let source =
    "
pub fn loader() { Nil }
pub fn view() { Nil }
fn private_helper() { Nil }
pub fn action() { Nil }
"
  let assert Ok(module) = glance_parse(source)
  let names = scanner.extract_public_function_names(module)
  let assert True = list.contains(names, "loader")
  let assert True = list.contains(names, "view")
  let assert True = list.contains(names, "action")
  let assert False = list.contains(names, "private_helper")
}

pub fn extract_no_public_functions_test() {
  let source = "fn helper() { Nil }\n"
  let assert Ok(module) = glance_parse(source)
  let names = scanner.extract_public_function_names(module)
  let assert [] = names
}

// --- Full directory scanning tests ---

pub fn scan_routes_creates_route_definitions_test() {
  // Create a temporary routes directory
  let test_dir = "/tmp/beacon_test_routes_" <> unique_id()
  let assert Ok(Nil) = simplifile.create_directory_all(test_dir)

  // Create route files
  let assert Ok(Nil) =
    simplifile.write(
      test_dir <> "/index.gleam",
      "pub fn view() { Nil }\npub fn loader() { Nil }\n",
    )
  let assert Ok(Nil) = simplifile.create_directory_all(test_dir <> "/about")
  let assert Ok(Nil) =
    simplifile.write(
      test_dir <> "/about/index.gleam",
      "pub fn view() { Nil }\n",
    )

  // Scan
  let assert Ok(routes) = scanner.scan_routes(test_dir)
  let assert True = list.length(routes) == 2

  // Cleanup
  let assert Ok(Nil) = simplifile.delete(test_dir)
}

pub fn scan_routes_nonexistent_dir_returns_empty_test() {
  let assert Ok(routes) = scanner.scan_routes("/tmp/beacon_nonexistent_dir_xyz")
  let assert [] = routes
}

pub fn scan_routes_detects_dynamic_params_test() {
  let test_dir = "/tmp/beacon_test_routes_dyn_" <> unique_id()
  let assert Ok(Nil) = simplifile.create_directory_all(test_dir <> "/blog")
  let assert Ok(Nil) =
    simplifile.write(
      test_dir <> "/blog/[slug].gleam",
      "pub fn view() { Nil }\npub fn loader() { Nil }\n",
    )

  let assert Ok(routes) = scanner.scan_routes(test_dir)
  let assert [route] = routes
  let assert ["blog", ":slug"] = route.path_segments
  let assert True = route.has_view
  let assert True = route.has_loader
  let assert False = route.has_action

  let assert Ok(Nil) = simplifile.delete(test_dir)
}

// --- Helpers ---

fn glance_parse(source: String) -> Result(glance.Module, glance.Error) {
  glance.module(source)
}

fn unique_id() -> String {
  do_unique_id()
}

@external(erlang, "beacon_test_ffi", "unique_ref")
fn do_unique_id() -> String
