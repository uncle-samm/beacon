/// Build system tests — verify codec generation produces correct output.
/// Tests the build pipeline through the analyzer + codec generation.
import beacon/build
import beacon/build/analyzer
import gleam/erlang/process
import gleam/list
import gleam/string
import simplifile

// === Codec Generation Correctness Tests ===
// These verify the analyzer produces the right inputs for codec generation.
// Note: Basic model field detection is tested in build_codec_test.gleam
// (standard_app_codec_fields_test). Tests here cover complementary aspects.

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

pub fn source_root_resolves_nested_app_modules_test() {
  let assert "src" = build.source_root("src/app/model.gleam")
  let assert "examples/domains/src" =
    build.source_root("examples/domains/src/app.gleam")
  let assert "src" = build.source_root("src/app.gleam")
}

pub fn source_freshness_detects_newer_nested_app_source_test() {
  let temp_root = "build/beacon_test_manifest_freshness"
  let src_root = temp_root <> "/src"
  let page_path = src_root <> "/pages/home.gleam"
  let manifest_path = temp_root <> "/priv/static/beacon_client.manifest"

  case simplifile.delete(temp_root) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
  let assert Ok(Nil) = simplifile.create_directory_all(src_root <> "/pages")
  let assert Ok(Nil) =
    simplifile.create_directory_all(temp_root <> "/priv/static")
  let assert Ok(Nil) =
    simplifile.write(page_path, "pub fn title() { \"Home\" }")
  process.sleep(1200)
  let assert Ok(Nil) = simplifile.write(manifest_path, "beacon_client_old.js")
  let assert False = build.is_any_source_newer_than(manifest_path, [src_root])

  process.sleep(1200)
  let assert Ok(Nil) =
    simplifile.write(page_path, "pub fn title() { \"Home updated\" }")
  let assert True = build.is_any_source_newer_than(manifest_path, [src_root])

  case simplifile.delete(temp_root) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
}

pub fn source_freshness_treats_missing_manifest_as_stale_test() {
  let temp_root = "build/beacon_test_missing_manifest_freshness"
  let src_root = temp_root <> "/src"
  let manifest_path = temp_root <> "/priv/static/beacon_client.manifest"

  case simplifile.delete(temp_root) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
  let assert Ok(Nil) = simplifile.create_directory_all(src_root)
  let assert Ok(Nil) = simplifile.write(src_root <> "/main.gleam", "")
  let assert True = build.is_any_source_newer_than(manifest_path, [src_root])

  case simplifile.delete(temp_root) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
}

pub fn resolve_transitive_external_sources_recurses_through_user_modules_test() {
  let temp_root = "build/beacon_test_transitive_sources"
  let src_root = temp_root <> "/src"
  let app_path = src_root <> "/app.gleam"
  let models_path = src_root <> "/types/models.gleam"
  let enums_path = src_root <> "/types/enums.gleam"

  case simplifile.delete(temp_root) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
  let assert Ok(Nil) = simplifile.create_directory_all(src_root <> "/types")
  let assert Ok(Nil) =
    simplifile.write(
      app_path,
      "import types/models\npub type Model { Model(status: models.AgentRunStatus) }\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      models_path,
      "import types/enums\npub type AgentRunStatus { Pending Running Done }\n",
    )
  let assert Ok(Nil) =
    simplifile.write(enums_path, "pub type AgentType { Codex Gemini }\n")

  let assert Ok(app_source) = simplifile.read(app_path)
  let sources = build.resolve_transitive_external_sources(app_source, src_root)
  let module_paths = list.map(sources, fn(s) { s.1 })
  let assert True = list.contains(module_paths, "types/models")
  let assert True = list.contains(module_paths, "types/enums")
  let assert False = list.contains(module_paths, "app")

  case simplifile.delete(temp_root) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
}

pub fn resolve_transitive_framework_sources_recurses_through_beacon_modules_test() {
  let source =
    "
import beacon/application

pub type Model { Model }
pub type Msg { Ping }

pub fn update(model: Model, msg: Msg) -> Model { model }
pub fn view(model: Model) { model }
"

  let sources = build.resolve_transitive_framework_sources([source], ".")
  let module_paths = list.map(sources, fn(s) { s.1 })
  let assert True = list.contains(module_paths, "beacon/application")
  let assert True = list.contains(module_paths, "beacon/route")
}

pub fn generate_external_imports_emits_explicit_aliases_test() {
  let app_source =
    "
import types/models

pub type Model { Model(service: models.ThreadService) }
pub type Msg { Ping }
pub fn update(model: Model, msg: Msg) -> Model { model }
pub fn view(model: Model) { model }
"
  let models_source =
    "
import types/enums

pub type ThreadService {
  ThreadService(status: enums.AgentRunStatus)
}
"
  let enums_source =
    "
pub type AgentRunStatus {
  Pending
  Running
}
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [
      #("models", "types/models", models_source),
      #("enums", "types/enums", enums_source),
    ])

  let imports = build.generate_external_imports(analysis, app_source, False)
  let assert True = string.contains(imports, "import types/models as models")
  let assert True = string.contains(imports, "import types/enums as enums")
}

pub fn generate_external_imports_preserves_nested_app_and_type_paths_test() {
  let app_source =
    "
import server_state
import types/models

pub type Model { Model(service: models.ThreadService) }
pub type Msg { Ping }
pub fn update(model: Model, msg: Msg) -> Model { model }
pub fn view(model: Model) { model }
"
  let server_source =
    "
import types/enums

pub type ServerState {
  ServerState(status: enums.AgentRunStatus)
}
"
  let models_source =
    "
import types/enums

pub type ThreadService {
  ThreadService(status: enums.AgentRunStatus)
}
"
  let enums_source =
    "
pub type AgentRunStatus {
  Pending
  Running
}
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [
      #("server_state", "app/server_state", server_source),
      #("models", "types/models", models_source),
      #("enums", "types/enums", enums_source),
    ])

  let imports = build.generate_external_imports(analysis, app_source, False)
  let assert True =
    string.contains(imports, "import app/server_state as server_state")
  let assert True = string.contains(imports, "import types/models as models")
  let assert True = string.contains(imports, "import types/enums as enums")
}

// Note: Server field exclusion is tested in build_codec_test.gleam
// (app_with_server_excludes_server_from_model_fields_test,
//  server_fields_tracked_separately_test).

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
  let assert Ok(item_type) =
    list.find(analysis.custom_types, fn(ct) { ct.name == "Item" })
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
