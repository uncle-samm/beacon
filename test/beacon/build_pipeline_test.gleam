/// Build pipeline tests — verify the analysis pipeline works correctly
/// against real example apps and across rebuild scenarios.

import beacon/build/analyzer
import gleam/list
import simplifile

// === Example App Analysis Tests ===

pub fn counter_example_analyzes_correctly_test() {
  let assert Ok(source) =
    simplifile.read("examples/counter/src/counter.gleam")
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert False = analysis.has_server
  let assert False = analysis.has_local
  let assert True =
    list.any(analysis.model_fields, fn(f) { f.name == "count" })
  let assert True =
    list.any(analysis.msg_variants, fn(v) { v.name == "Increment" })
  let assert True =
    list.any(analysis.msg_variants, fn(v) { v.name == "Decrement" })
}

pub fn privacy_demo_analyzes_correctly_test() {
  let assert Ok(source) =
    simplifile.read("examples/privacy_demo/src/privacy_demo.gleam")
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_server
  let assert False = analysis.has_local
  let assert True = list.length(analysis.server_fields) >= 1
  // Model fields should NOT include server fields
  let server_field_names =
    list.map(analysis.server_fields, fn(f) { f.name })
  list.each(server_field_names, fn(name) {
    let assert False =
      list.any(analysis.model_fields, fn(f) { f.name == name })
  })
  let assert True = list.length(analysis.computed_fields) >= 1
}

pub fn counter_local_analyzes_correctly_test() {
  let assert Ok(source) =
    simplifile.read("examples/counter_local/src/counter_local.gleam")
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_local
  let assert False = analysis.has_server
}

pub fn domains_multi_file_analyzes_correctly_test() {
  let assert Ok(app_source) =
    simplifile.read("examples/domains/src/app.gleam")
  let externals = case
    simplifile.read("examples/domains/src/domains/auth.gleam"),
    simplifile.read("examples/domains/src/domains/items.gleam")
  {
    Ok(auth_src), Ok(items_src) -> [
      #("auth", "domains/auth", auth_src),
      #("items", "domains/items", items_src),
    ]
    _, _ -> []
  }
  // Both external files must be readable
  let assert True = list.length(externals) == 2
  let assert Ok(analysis) = analyzer.analyze_multi(app_source, externals)
  let assert True = list.length(analysis.custom_types) >= 1
  let assert True = list.length(analysis.model_fields) >= 1
}

// === Idempotency Tests ===

pub fn analysis_with_different_source_produces_different_result_test() {
  let source_v1 =
    "
pub type Model {
  Model(count: Int)
}
pub type Msg {
  Inc
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let source_v2 =
    "
pub type Model {
  Model(count: Int, name: String, items: List(String))
}
pub type Msg {
  Inc
  Dec
  Add(String)
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let assert Ok(a1) = analyzer.analyze(source_v1)
  let assert Ok(a2) = analyzer.analyze(source_v2)
  let assert True = list.length(a1.model_fields) == 1
  let assert True = list.length(a2.model_fields) == 3
  let assert True = list.length(a1.msg_variants) == 1
  let assert True = list.length(a2.msg_variants) == 3
}

// === Rebuild Scenario Tests ===

pub fn analysis_after_model_change_reflects_new_fields_test() {
  let source_v1 =
    "
pub type Model {
  Model(count: Int)
}
pub type Msg {
  Inc
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let source_v2 =
    "
pub type Model {
  Model(count: Int, name: String)
}
pub type Msg {
  Inc
  SetName(String)
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let assert Ok(a1) = analyzer.analyze(source_v1)
  let assert True = list.length(a1.model_fields) == 1
  let assert False =
    list.any(a1.model_fields, fn(f) { f.name == "name" })

  let assert Ok(a2) = analyzer.analyze(source_v2)
  let assert True = list.length(a2.model_fields) == 2
  let assert True =
    list.any(a2.model_fields, fn(f) { f.name == "name" })
}

pub fn analysis_after_adding_server_type_detects_it_test() {
  let source_v1 =
    "
pub type Model {
  Model(count: Int)
}
pub type Msg {
  Inc
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let source_v2 =
    "
pub type Model {
  Model(count: Int)
}
pub type Server {
  Server(api_key: String)
}
pub type Msg {
  Inc
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let assert Ok(a1) = analyzer.analyze(source_v1)
  let assert False = a1.has_server

  let assert Ok(a2) = analyzer.analyze(source_v2)
  let assert True = a2.has_server
  let assert True =
    list.any(a2.server_fields, fn(f) { f.name == "api_key" })
}
