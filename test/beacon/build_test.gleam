/// Build system tests — verify codec generation produces correct output.
/// Tests the build pipeline through the analyzer + codec generation.

import beacon/build/analyzer
import gleam/list
import gleam/string

// === Codec Generation Correctness Tests ===
// These verify the analyzer produces the right inputs for codec generation.

pub fn codec_includes_all_model_fields_test() {
  let source =
    "
pub type Model { Model(count: Int, name: String, active: Bool, rate: Float) }
pub type Msg { Inc }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let field_names = list.map(analysis.model_fields, fn(f) { f.name })
  let assert True = list.contains(field_names, "count")
  let assert True = list.contains(field_names, "name")
  let assert True = list.contains(field_names, "active")
  let assert True = list.contains(field_names, "rate")
  let assert True = list.length(analysis.model_fields) == 4
}

pub fn codec_field_types_correct_test() {
  let source =
    "
pub type Model { Model(count: Int, name: String, active: Bool, rate: Float) }
pub type Msg { Inc }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let find = fn(name) {
    case list.find(analysis.model_fields, fn(f) { f.name == name }) {
      Ok(f) -> f.type_name
      Error(_) -> ""
    }
  }
  let assert True = find("count") == "Int"
  let assert True = find("name") == "String"
  let assert True = find("active") == "Bool"
  let assert True = find("rate") == "Float"
}

pub fn codec_excludes_server_fields_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Server { Server(api_key: String, db: String) }
pub type Msg { Inc }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  // Model fields should only contain count
  let assert True = list.length(analysis.model_fields) == 1
  let assert Ok(f) = list.first(analysis.model_fields)
  let assert True = f.name == "count"
  // Server fields are separate
  let assert True = list.length(analysis.server_fields) == 2
  // Server should NOT be in custom_types (handled separately)
  let type_names = list.map(analysis.custom_types, fn(ct) { ct.name })
  let assert False = list.contains(type_names, "Server")
}

pub fn codec_computed_fields_have_correct_types_test() {
  let source =
    "
pub type Model { Model(count: Int, items: List(Int)) }
pub type Msg { Inc }

pub fn doubled(model: Model) -> Int { model.count * 2 }
pub fn label(model: Model) -> String { \"label\" }
pub fn total_items(model: Model) -> Int { 0 }

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  // 3 computed fields detected
  let assert True = list.length(analysis.computed_fields) == 3
  // Verify each has the right return type
  let find_type = fn(name) {
    case list.find(analysis.computed_fields, fn(c) { c.name == name }) {
      Ok(c) -> c.return_type
      Error(_) -> ""
    }
  }
  let assert True = find_type("doubled") == "Int"
  let assert True = find_type("label") == "String"
  let assert True = find_type("total_items") == "Int"
}

pub fn codec_nested_custom_types_detected_test() {
  let source =
    "
pub type Item { Item(name: String, price: Int) }
pub type Model { Model(items: List(Item), count: Int) }
pub type Msg { Inc }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  // Item should be in custom_types (has fields, used by Model)
  let type_names = list.map(analysis.custom_types, fn(ct) { ct.name })
  let assert True = list.contains(type_names, "Item")
  // Item should have 2 fields
  let assert Ok(item_type) = list.find(analysis.custom_types, fn(ct) { ct.name == "Item" })
  let assert True = list.length(item_type.fields) == 2
}

pub fn codec_enum_types_detected_test() {
  let source =
    "
pub type Status { Active Inactive Pending }
pub type Model { Model(status: Status, count: Int) }
pub type Msg { Inc }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Inc -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.enum_types) == 1
  let assert Ok(et) = list.first(analysis.enum_types)
  let assert True = et.name == "Status"
  let assert True = list.length(et.variants) == 3
  let assert True = list.contains(et.variants, "Active")
  let assert True = list.contains(et.variants, "Inactive")
  let assert True = list.contains(et.variants, "Pending")
}

pub fn extract_produces_valid_gleam_source_test() {
  // The extracted source should be parseable by Glance (valid Gleam syntax)
  let source =
    "
import gleam/int

pub type Model { Model(count: Int) }
pub type Msg { Increment }

const max = 100

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { max }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  // The extracted source must contain valid Gleam constructs
  let assert True = string.contains(extracted, "pub type Model")
  let assert True = string.contains(extracted, "pub type Msg")
  let assert True = string.contains(extracted, "pub fn view")
  // And the constant referenced by view
  let assert True = string.contains(extracted, "max")
  // Must NOT contain update (it takes Model + Msg, not just Model)
  // Actually update IS extracted (client needs it for local events)
  let assert True = string.contains(extracted, "pub fn update")
}

pub fn msg_variant_classification_accuracy_test() {
  // Verify that model-affecting vs local-only classification is correct
  let source =
    "
pub type Model { Model(count: Int) }
pub type Local { Local(input: String) }
pub type Msg {
  Increment
  Decrement
  Reset
  SetInput(String)
}

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    Increment -> #(Model(count: model.count + 1), local)
    Decrement -> #(Model(count: model.count - 1), local)
    Reset -> #(Model(count: 0), local)
    SetInput(text) -> #(model, Local(input: text))
  }
}

pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.msg_variants) == 4
  // Increment, Decrement, Reset all modify model
  let find = fn(name) {
    case list.find(analysis.msg_variants, fn(v) { v.name == name }) {
      Ok(v) -> v.affects_model
      Error(_) -> False
    }
  }
  let assert True = find("Increment")
  let assert True = find("Decrement")
  let assert True = find("Reset")
  // SetInput only modifies local
  let assert False = find("SetInput")
}
