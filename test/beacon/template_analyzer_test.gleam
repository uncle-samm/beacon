import beacon/template/analyzer
import gleam/list

// --- analyze_view_source tests ---

pub fn static_view_no_deps_test() {
  let source =
    "
pub fn view(model: Model) -> Node(Msg) {
  element.el(\"div\", [], [element.text(\"Hello\")])
}
"
  let assert Ok(deps) = analyzer.analyze_view_source(source, "model")
  let assert [] = deps
}

pub fn single_field_dependency_test() {
  let source =
    "
pub fn view(model: Model) -> Node(Msg) {
  element.el(\"div\", [], [element.text(model.name)])
}
"
  let assert Ok(deps) = analyzer.analyze_view_source(source, "model")
  let assert True = list.contains(deps, "name")
}

pub fn multiple_field_dependencies_test() {
  let source =
    "
pub fn view(model: Model) -> Node(Msg) {
  element.el(\"div\", [], [
    element.text(model.name),
    element.text(model.count),
  ])
}
"
  let assert Ok(deps) = analyzer.analyze_view_source(source, "model")
  let assert True = list.contains(deps, "name")
  let assert True = list.contains(deps, "count")
}

pub fn duplicate_deps_deduplicated_test() {
  let source =
    "
pub fn view(model: Model) -> Node(Msg) {
  element.el(\"div\", [], [
    element.text(model.name),
    element.text(model.name),
  ])
}
"
  let assert Ok(deps) = analyzer.analyze_view_source(source, "model")
  // Should have "name" only once
  let assert 1 = list.length(list.filter(deps, fn(d) { d == "name" }))
}

pub fn string_concat_with_model_test() {
  let source =
    "
pub fn view(model: Model) -> Node(Msg) {
  element.text(\"Count: \" <> int.to_string(model.count))
}
"
  let assert Ok(deps) = analyzer.analyze_view_source(source, "model")
  let assert True = list.contains(deps, "count")
}

pub fn model_passed_to_function_test() {
  let source =
    "
pub fn view(model: Model) -> Node(Msg) {
  render_header(model)
}
"
  let assert Ok(deps) = analyzer.analyze_view_source(source, "model")
  // Passing the whole model → wildcard dependency
  let assert True = list.contains(deps, "*")
}

pub fn no_view_function_error_test() {
  let source = "pub fn other() { Nil }\n"
  let assert Error("No public 'view' function found") =
    analyzer.analyze_view_source(source, "model")
}

pub fn private_view_function_error_test() {
  let source = "fn view(model: Model) { Nil }\n"
  let assert Error("No public 'view' function found") =
    analyzer.analyze_view_source(source, "model")
}

pub fn invalid_source_error_test() {
  let source = "this is not valid gleam @@@@"
  let assert Error("Failed to parse source") =
    analyzer.analyze_view_source(source, "model")
}

pub fn let_binding_with_model_field_test() {
  let source =
    "
pub fn view(model: Model) -> Node(Msg) {
  let name = model.username
  element.text(name)
}
"
  let assert Ok(deps) = analyzer.analyze_view_source(source, "model")
  let assert True = list.contains(deps, "username")
}

pub fn case_expression_with_model_test() {
  let source =
    "
pub fn view(model: Model) -> Node(Msg) {
  case model.active {
    True -> element.text(\"Active\")
    False -> element.text(\"Inactive\")
  }
}
"
  let assert Ok(deps) = analyzer.analyze_view_source(source, "model")
  let assert True = list.contains(deps, "active")
}

// --- Classification type tests ---

pub fn static_is_static_test() {
  let assert True = analyzer.is_static(analyzer.Static)
}

pub fn static_is_not_dynamic_test() {
  let assert False = analyzer.is_dynamic(analyzer.Static)
}

pub fn dynamic_is_dynamic_test() {
  let assert True = analyzer.is_dynamic(analyzer.Dynamic(["field"]))
}

pub fn dynamic_is_not_static_test() {
  let assert False = analyzer.is_static(analyzer.Dynamic(["field"]))
}
