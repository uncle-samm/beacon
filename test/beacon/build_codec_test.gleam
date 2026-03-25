/// Build codec tests — verify the analysis pipeline produces correct
/// codec inputs for every app type (standard, app_with_server, app_with_local, multi-file).

import beacon/build/analyzer
import gleam/list
import gleam/string

// === Codec Analysis Tests ===

pub fn standard_app_codec_fields_test() {
  let source =
    "
pub type Model {
  Model(count: Int, name: String, active: Bool)
}
pub type Msg {
  Inc
  Dec
  SetName(String)
}
pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Inc -> Model(..model, count: model.count + 1)
    Dec -> Model(..model, count: model.count - 1)
    SetName(n) -> Model(..model, name: n)
  }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert False = analysis.has_server
  let assert False = analysis.has_local
  let assert True = list.length(analysis.model_fields) == 3
  let assert True =
    list.any(analysis.model_fields, fn(f) { f.name == "count" })
  let assert True =
    list.any(analysis.model_fields, fn(f) { f.name == "name" })
  let assert True =
    list.any(analysis.model_fields, fn(f) { f.name == "active" })
}

pub fn app_with_server_excludes_server_from_model_fields_test() {
  let source =
    "
pub type Model {
  Model(count: Int, username: String)
}
pub type Server {
  Server(api_key: String, db_url: String)
}
pub type Msg {
  Inc
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_server
  let assert True =
    list.any(analysis.model_fields, fn(f) { f.name == "count" })
  let assert True =
    list.any(analysis.model_fields, fn(f) { f.name == "username" })
  // Server fields must NOT be in model_fields
  let assert False =
    list.any(analysis.model_fields, fn(f) { f.name == "api_key" })
  let assert False =
    list.any(analysis.model_fields, fn(f) { f.name == "db_url" })
}

pub fn app_with_server_detects_has_server_flag_test() {
  let source =
    "
pub type Model {
  Model(count: Int)
}
pub type Server {
  Server(secret: String)
}
pub type Msg {
  Inc
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_server
}

pub fn app_with_local_detects_has_local_flag_test() {
  let source =
    "
pub type Model {
  Model(count: Int)
}
pub type Local {
  Local(input: String)
}
pub type Msg {
  Inc
  SetInput(String)
}
pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  #(model, local)
}
pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_local
  let assert False = analysis.has_server
}

pub fn server_fields_tracked_separately_test() {
  let source =
    "
pub type Model {
  Model(name: String)
}
pub type Server {
  Server(api_key: String, db_pool: String)
}
pub type Msg {
  SetName(String)
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.server_fields) == 2
  let assert True =
    list.any(analysis.server_fields, fn(f) { f.name == "api_key" })
  let assert True =
    list.any(analysis.server_fields, fn(f) { f.name == "db_pool" })
}

// === Security Tests ===

pub fn server_constants_excluded_from_client_source_test() {
  let source =
    "
const server_api_key = \"sk-secret-12345\"
const app_name = \"MyApp\"

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
  let assert Ok(client_source) = analyzer.extract_client_source(source)
  let assert False = string.contains(client_source, "server_api_key")
  let assert False = string.contains(client_source, "sk-secret-12345")
}

pub fn server_type_never_in_client_source_test() {
  let source =
    "
pub type Model {
  Model(count: Int)
}
pub type Server {
  Server(api_key: String, db_url: String)
}
pub type Msg {
  Inc
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let assert Ok(client_source) = analyzer.extract_client_source(source)
  let assert False = string.contains(client_source, "pub type Server")
  let assert True = string.contains(client_source, "pub type Model")
}

pub fn computed_fields_only_take_model_not_server_test() {
  let source =
    "
pub type Model {
  Model(price: Int, qty: Int)
}
pub type Server {
  Server(api_key: String)
}
pub type Msg {
  Inc
}

pub fn total(model: Model) -> Int {
  model.price * model.qty
}

pub fn validate_key(server: Server) -> Bool {
  True
}

pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True =
    list.any(analysis.computed_fields, fn(cf) { cf.name == "total" })
  let assert False =
    list.any(analysis.computed_fields, fn(cf) { cf.name == "validate_key" })
}

// === Multi-file Tests ===

pub fn multi_file_resolves_external_model_fields_test() {
  let app_source =
    "
import task

pub type Model {
  Model(items: List(task.Item), filter: String)
}
pub type Msg {
  AddItem
  ClearAll
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let external_source =
    "
pub type Item {
  Item(id: Int, text: String, done: Bool)
}
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [#("task", "task", external_source)])
  let assert True =
    list.any(analysis.model_fields, fn(f) { f.name == "items" })
  let assert True =
    list.any(analysis.model_fields, fn(f) { f.name == "filter" })
  let assert True =
    list.any(analysis.custom_types, fn(ct) { ct.name == "Item" })
}

pub fn multi_file_with_server_test() {
  let app_source =
    "
import task

pub type Model {
  Model(items: List(task.Item))
}
pub type Server {
  Server(db_pool: String)
}
pub type Msg {
  AddItem
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let external_source =
    "
pub type Item {
  Item(id: Int, text: String)
}
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [#("task", "task", external_source)])
  let assert True = analysis.has_server
  let assert True =
    list.any(analysis.custom_types, fn(ct) { ct.name == "Item" })
  let assert True =
    list.any(analysis.server_fields, fn(f) { f.name == "db_pool" })
  let assert False =
    list.any(analysis.model_fields, fn(f) { f.name == "db_pool" })
}

// === Substate Tests ===

pub fn substates_detected_with_server_type_test() {
  let source =
    "
pub type Item {
  Item(id: Int, text: String)
}
pub type Model {
  Model(items: List(Item), count: Int)
}
pub type Server {
  Server(api_key: String)
}
pub type Msg {
  Add
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_server
  let assert True =
    list.any(analysis.substates, fn(s) { s.field_name == "items" })
  let assert False =
    list.any(analysis.substates, fn(s) { s.field_name == "count" })
}

// === Multi-file Server Detection ===

pub fn server_type_detected_in_external_module_test() {
  // When Server/ServerState type is in a separate file (e.g., server_state.gleam),
  // analyze_multi must detect has_server from external sources.
  let app_source =
    "
import server_state

pub type Model {
  Model(count: Int, name: String)
}
pub type Msg {
  Inc
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let server_source =
    "
pub type ServerState {
  ServerState(db_pool: String, api_key: String)
}
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [
      #("server_state", "app/server_state", server_source),
    ])
  // has_server detected from external module
  let assert True = analysis.has_server
  // Server module and type name tracked for codec generation
  let assert True = analysis.server_module == "server_state"
  let assert True = analysis.server_type_name == "ServerState"
  // server_fields populated from external ServerState type
  let assert True =
    list.any(analysis.server_fields, fn(f) { f.name == "db_pool" })
  let assert True =
    list.any(analysis.server_fields, fn(f) { f.name == "api_key" })
  // Model fields unaffected
  let assert True =
    list.any(analysis.model_fields, fn(f) { f.name == "count" })
  let assert False =
    list.any(analysis.model_fields, fn(f) { f.name == "db_pool" })
}

// === Option Type Detection ===

pub fn option_fields_detected_correctly_test() {
  let source =
    "
import gleam/option

pub type Model {
  Model(
    name: String,
    email: option.Option(String),
    age: option.Option(Int),
    active: Bool,
  )
}
pub type Msg {
  SetName(String)
}
pub fn update(model: Model, msg: Msg) -> Model {
  model
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let email_field =
    list.find(analysis.model_fields, fn(f) { f.name == "email" })
  let assert Ok(ef) = email_field
  let assert True = ef.type_name == "Option"
  let assert True = ef.inner_type == "String"

  let age_field =
    list.find(analysis.model_fields, fn(f) { f.name == "age" })
  let assert Ok(af) = age_field
  let assert True = af.type_name == "Option"
  let assert True = af.inner_type == "Int"
}
