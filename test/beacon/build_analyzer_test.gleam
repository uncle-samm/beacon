import beacon/build/analyzer
import gleam/list
import gleam/string

pub fn analyzes_counter_local_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Local { Local(input: String, menu_open: Bool) }
pub type Msg {
  Increment
  Decrement
  SetInput(String)
  ToggleMenu
}

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    Increment -> #(Model(count: model.count + 1), local)
    Decrement -> #(Model(count: model.count - 1), local)
    SetInput(text) -> #(model, Local(..local, input: text))
    ToggleMenu -> #(model, Local(..local, menu_open: !local.menu_open))
  }
}

pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_local
  let assert 4 = list.length(analysis.msg_variants)
  // Increment and Decrement modify model
  let assert True = find_variant(analysis.msg_variants, "Increment").affects_model
  let assert True = find_variant(analysis.msg_variants, "Decrement").affects_model
  // SetInput and ToggleMenu only modify local
  let assert False = find_variant(analysis.msg_variants, "SetInput").affects_model
  let assert False = find_variant(analysis.msg_variants, "ToggleMenu").affects_model
}

pub fn analyzes_simple_counter_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg {
  Increment
  Decrement
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + 1)
    Decrement -> Model(count: model.count - 1)
  }
}

pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert False = analysis.has_local
  // Both modify model
  let assert True = find_variant(analysis.msg_variants, "Increment").affects_model
  let assert True = find_variant(analysis.msg_variants, "Decrement").affects_model
}

pub fn extracts_model_fields_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Local { Local(input: String, menu_open: Bool) }
pub type Msg { Increment }
pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg { Increment -> #(Model(count: model.count + 1), local) }
}
pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert 1 = list.length(analysis.model_fields)
  let assert Ok(field) = list.first(analysis.model_fields)
  let assert "count" = field.name
  let assert "Int" = field.type_name
}

pub fn detects_direct_init_update_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Local { Local(input: String) }
pub type Msg { Increment }
pub fn init() -> Model { Model(count: 0) }
pub fn init_local(_m: Model) -> Local { Local(input: \"\") }
pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg { Increment -> #(Model(count: model.count + 1), local) }
}
pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_direct_init
  let assert True = analysis.has_direct_update
}

pub fn detects_factory_pattern_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Local { Local(input: String) }
pub type Msg { Increment }
pub fn init_local(_m: Model) -> Local { Local(input: \"\") }
pub fn make_update(store) -> fn(Model, Local, Msg) -> #(Model, Local) {
  fn(model, local, msg) {
    case msg { Increment -> #(Model(count: model.count + 1), local) }
  }
}
pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert False = analysis.has_direct_init
  let assert False = analysis.has_direct_update
}

pub fn no_msg_type_error_test() {
  let source = "pub fn update(m, msg) { m }\npub fn view(m) { m }\npub type Model { M }\n"
  let assert Error(_) = analyzer.analyze(source)
}

fn find_variant(
  variants: List(analyzer.MsgVariant),
  name: String,
) -> analyzer.MsgVariant {
  let assert Ok(v) =
    list.find(variants, fn(v) { v.name == name })
  v
}

// ===== Purity Validation Tests =====

pub fn pure_module_passes_validation_test() {
  let source =
    "
import beacon
import beacon/html
import gleam/int
import gleam/list
import gleam/string

pub type Model { Model(count: Int) }
pub type Local { Local(input: String) }
pub type Msg {
  Increment
  SetInput(String)
}

pub fn init() -> Model { Model(count: 0) }
pub fn init_local(_m: Model) -> Local { Local(input: \"\") }
pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    Increment -> #(Model(count: model.count + 1), local)
    SetInput(t) -> #(model, Local(input: t))
  }
}
pub fn view(model: Model, local: Local) { model }
"
  let assert Ok(Nil) = analyzer.validate_purity(source)
}

pub fn impure_store_import_fails_validation_test() {
  let source =
    "
import beacon
import beacon/store

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let assert Error(msg) = analyzer.validate_purity(source)
  let assert True = string.contains(msg, "beacon/store")
}

pub fn impure_effect_import_fails_validation_test() {
  let source =
    "
import beacon
import beacon/effect

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let assert Error(msg) = analyzer.validate_purity(source)
  let assert True = string.contains(msg, "beacon/effect")
}

pub fn impure_erlang_process_import_fails_test() {
  let source =
    "
import beacon
import gleam/erlang/process

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let assert Error(msg) = analyzer.validate_purity(source)
  let assert True = string.contains(msg, "gleam/erlang/process")
}

pub fn impure_external_erlang_fails_validation_test() {
  let source =
    "
import beacon

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }

@external(erlang, \"erlang\", \"unique_integer\")
fn unique_int() -> Int
"
  let assert Error(msg) = analyzer.validate_purity(source)
  let assert True = string.contains(msg, "unique_int")
  let assert True = string.contains(msg, "@external(erlang")
}

pub fn multiple_purity_errors_reported_test() {
  let source =
    "
import beacon
import beacon/store
import beacon/pubsub

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }

@external(erlang, \"erlang\", \"unique_integer\")
fn unique_int() -> Int
"
  let assert Error(msg) = analyzer.validate_purity(source)
  // All three errors should be reported
  let assert True = string.contains(msg, "beacon/store")
  let assert True = string.contains(msg, "beacon/pubsub")
  let assert True = string.contains(msg, "unique_int")
}

pub fn safe_imports_pass_validation_test() {
  // These imports are all pure Gleam — should pass
  let source =
    "
import beacon
import beacon/html
import beacon/element
import gleam/int
import gleam/list
import gleam/string
import gleam/float
import gleam/bool
import gleam/option
import gleam/result
import gleam/dict
import gleam/json

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let assert Ok(Nil) = analyzer.validate_purity(source)
}

// ===== AST Extraction Tests =====

pub fn extracts_pure_types_and_functions_test() {
  let source =
    "import beacon
import beacon/html
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Local {
  Local(input: String)
}

pub type Msg {
  Increment
  SetInput(String)
}

pub fn init() -> Model {
  Model(count: 0)
}

pub fn init_local(_m: Model) -> Local {
  Local(input: \"\")
}

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    Increment -> #(Model(count: model.count + 1), local)
    SetInput(t) -> #(model, Local(input: t))
  }
}

pub fn view(model: Model, local: Local) { model }

pub fn start() {
  todo
}
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  // Should contain types, init, update, view
  let assert True = string.contains(extracted, "pub type Model")
  let assert True = string.contains(extracted, "pub type Local")
  let assert True = string.contains(extracted, "pub type Msg")
  let assert True = string.contains(extracted, "pub fn init()")
  let assert True = string.contains(extracted, "pub fn init_local(")
  // Pure update IS extracted — enables LOCAL events + optimistic updates
  let assert True = string.contains(extracted, "pub fn update(")
  let assert True = string.contains(extracted, "pub fn view(")
  // Should NOT contain start
  let assert False = string.contains(extracted, "pub fn start()")
  // Should contain safe imports
  let assert True = string.contains(extracted, "import beacon")
  let assert True = string.contains(extracted, "import gleam/int")
}

pub fn skips_server_imports_in_extraction_test() {
  let source =
    "import beacon
import beacon/store
import beacon/effect
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  // Should contain safe imports
  let assert True = string.contains(extracted, "import beacon")
  let assert True = string.contains(extracted, "import gleam/int")
  // Should NOT contain server-only imports
  let assert False = string.contains(extracted, "import beacon/store")
  let assert False = string.contains(extracted, "import beacon/effect")
}

pub fn skips_external_erlang_functions_test() {
  let source =
    "import beacon

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}

pub fn view(model: Model) { model }

@external(erlang, \"erlang\", \"unique_integer\")
fn unique_int() -> Int
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  // Should contain update and view
  // Pure update IS extracted — enables LOCAL events + optimistic updates
  let assert True = string.contains(extracted, "pub fn update(")
  let assert True = string.contains(extracted, "pub fn view(")
  // Should NOT contain the external function
  let assert False = string.contains(extracted, "unique_int")
  let assert False = string.contains(extracted, "@external")
}

pub fn preserves_helper_functions_test() {
  let source =
    "import beacon

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

fn helper(x: Int) -> Int {
  x + 1
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: helper(model.count)) }
}

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  // Should preserve helper functions
  let assert True = string.contains(extracted, "fn helper(")
}

// === Substate Detection Tests ===

pub fn detects_record_field_as_substate_test() {
  let source =
    "
pub type Settings { Settings(theme: String, language: String) }
pub type Model { Model(count: Int, settings: Settings) }
pub type Msg { Increment
  UpdateSettings }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(..model, count: model.count + 1)
    _ -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.substates) == 1
  let assert Ok(s) = list.first(analysis.substates)
  let assert True = s.field_name == "settings"
  let assert True = s.type_name == "Settings"
  let assert True = s.is_list == False
}

pub fn detects_list_record_as_substate_test() {
  let source =
    "
pub type Card { Card(id: Int, title: String) }
pub type Model { Model(cards: List(Card), next_id: Int) }
pub type Msg { AddCard }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { AddCard -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.substates) == 1
  let assert Ok(s) = list.first(analysis.substates)
  let assert True = s.field_name == "cards"
  let assert True = s.type_name == "Card"
  let assert True = s.is_list == True
}

pub fn primitives_not_substates_test() {
  let source =
    "
pub type Model { Model(count: Int, name: String, active: Bool) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.substates == []
}

pub fn enums_not_substates_test() {
  let source =
    "
pub type Status { Active
  Inactive
  Pending }
pub type Model { Model(status: Status, count: Int) }
pub type Msg { Toggle }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Toggle -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.substates == []
}

pub fn multiple_substates_test() {
  let source =
    "
pub type Card { Card(id: Int, title: String) }
pub type Message { Message(text: String, sender: String) }
pub type Model { Model(cards: List(Card), messages: List(Message), count: Int) }
pub type Msg { AddCard }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { AddCard -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.substates) == 2
}

// ===== Multi-file Analyzer Tests =====

pub fn analyzes_external_type_field_test() {
  // App module references auth.User from an external module
  let app_source =
    "
import domains/auth

pub type Model { Model(user: auth.User, count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(..model, count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let auth_source =
    "
pub type User { User(name: String, email: String) }
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [#("auth", "domains/auth", auth_source)])

  // Should detect the external User type
  let assert True = list.length(analysis.custom_types) == 1
  let assert Ok(ct) = list.first(analysis.custom_types)
  let assert True = ct.name == "User"
  let assert True = ct.module == "auth"
  let assert True = list.length(ct.fields) == 2

  // Model field should have module qualifier
  let assert Ok(user_field) =
    list.find(analysis.model_fields, fn(f) { f.name == "user" })
  let assert True = user_field.type_name == "User"
  let assert True = user_field.module == "auth"

  // Should be a substate (custom record type)
  let assert True = list.length(analysis.substates) == 1
  let assert Ok(s) = list.first(analysis.substates)
  let assert True = s.field_name == "user"
  let assert True = s.type_name == "User"
  let assert True = s.module == "auth"

  // Should have the imported module
  let assert True = list.length(analysis.imported_modules) == 1
}

pub fn analyzes_external_list_type_test() {
  // App references List(card.Card) from an external module
  let app_source =
    "
import domains/card

pub type Model { Model(cards: List(card.Card), count: Int) }
pub type Msg { AddCard }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { AddCard -> model }
}
pub fn view(model: Model) { model }
"
  let card_source =
    "
pub type Card { Card(id: Int, title: String, done: Bool) }
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [#("card", "domains/card", card_source)])

  // Should detect the external Card type
  let assert True = list.length(analysis.custom_types) == 1
  let assert Ok(ct) = list.first(analysis.custom_types)
  let assert True = ct.name == "Card"
  let assert True = ct.module == "card"

  // Model field should have inner_module qualifier
  let assert Ok(cards_field) =
    list.find(analysis.model_fields, fn(f) { f.name == "cards" })
  let assert True = cards_field.type_name == "List"
  let assert True = cards_field.inner_type == "Card"
  let assert True = cards_field.inner_module == "card"

  // Should be detected as a list substate
  let assert True = list.length(analysis.substates) == 1
  let assert Ok(s) = list.first(analysis.substates)
  let assert True = s.field_name == "cards"
  let assert True = s.type_name == "Card"
  let assert True = s.is_list == True
  let assert True = s.module == "card"
}

pub fn analyzes_external_enum_type_test() {
  // App references an enum type from an external module
  let app_source =
    "
import domains/status

pub type Model { Model(status: status.Status, count: Int) }
pub type Msg { Toggle }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Toggle -> model }
}
pub fn view(model: Model) { model }
"
  let status_source =
    "
pub type Status { Active
  Inactive
  Pending }
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [
      #("status", "domains/status", status_source),
    ])

  // Should detect the external enum type
  let assert True = list.length(analysis.enum_types) == 1
  let assert Ok(et) = list.first(analysis.enum_types)
  let assert True = et.name == "Status"
  let assert True = et.module == "status"
  let assert True = list.length(et.variants) == 3

  // Should NOT be a substate (enums are not substates)
  let assert True = analysis.substates == []
}

pub fn single_file_backward_compat_test() {
  // Existing single-file apps should work exactly as before
  let source =
    "
pub type Card { Card(id: Int, title: String) }
pub type Model { Model(cards: List(Card), count: Int) }
pub type Msg { AddCard }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { AddCard -> model }
}
pub fn view(model: Model) { model }
"
  // analyze_multi with empty externals should match analyze
  let assert Ok(analysis_single) = analyzer.analyze(source)
  let assert Ok(analysis_multi) = analyzer.analyze_multi(source, [])

  let assert True =
    list.length(analysis_single.custom_types)
    == list.length(analysis_multi.custom_types)
  let assert True =
    list.length(analysis_single.substates)
    == list.length(analysis_multi.substates)
  let assert True =
    list.length(analysis_single.model_fields)
    == list.length(analysis_multi.model_fields)
  let assert True = analysis_single.imported_modules == []
  let assert True = analysis_multi.imported_modules == []
}

pub fn mixed_local_and_external_test() {
  // Model with both local and external types
  let app_source =
    "
import domains/auth

pub type Settings { Settings(theme: String, language: String) }
pub type Model {
  Model(
    user: auth.User,
    settings: Settings,
    messages: List(auth.ChatMessage),
    count: Int,
  )
}
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(..model, count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let auth_source =
    "
pub type User { User(name: String, email: String) }
pub type ChatMessage { ChatMessage(text: String, sender: String) }
"
  let assert Ok(analysis) =
    analyzer.analyze_multi(app_source, [#("auth", "domains/auth", auth_source)])

  // Should have 3 custom types: 1 local (Settings) + 2 external (User, ChatMessage)
  let assert True = list.length(analysis.custom_types) == 3

  // Local Settings type should have module == ""
  let assert Ok(settings_ct) =
    list.find(analysis.custom_types, fn(ct) { ct.name == "Settings" })
  let assert True = settings_ct.module == ""

  // External User type should have module == "auth"
  let assert Ok(user_ct) =
    list.find(analysis.custom_types, fn(ct) { ct.name == "User" })
  let assert True = user_ct.module == "auth"

  // 3 substates: user (auth, single), settings (local, single), messages (auth, list)
  let assert True = list.length(analysis.substates) == 3

  // Check user substate
  let assert Ok(user_s) =
    list.find(analysis.substates, fn(s) { s.field_name == "user" })
  let assert True = user_s.module == "auth"
  let assert True = user_s.is_list == False

  // Check settings substate (local)
  let assert Ok(settings_s) =
    list.find(analysis.substates, fn(s) { s.field_name == "settings" })
  let assert True = settings_s.module == ""
  let assert True = settings_s.is_list == False

  // Check messages substate (external list)
  let assert Ok(messages_s) =
    list.find(analysis.substates, fn(s) { s.field_name == "messages" })
  let assert True = messages_s.module == "auth"
  let assert True = messages_s.is_list == True
}

pub fn user_module_passes_purity_test() {
  // Importing user domain modules should pass purity validation
  let source =
    "
import beacon
import domains/auth
import domains/chat

pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let assert Ok(Nil) = analyzer.validate_purity(source)
}

// === Constant Leak Prevention Tests ===

pub fn server_prefix_constant_not_extracted_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

const server_api_key = \"sk_live_abc123\"

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert False = string.contains(extracted, "server_api_key")
  let assert False = string.contains(extracted, "sk_live_abc123")
}

pub fn server_module_constant_not_extracted_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

const db_config = process.self()

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert False = string.contains(extracted, "db_config")
}

pub fn referenced_constant_is_extracted_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

const max_count = 100

pub fn view(model: Model) { max_count }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert True = string.contains(extracted, "max_count")
  let assert True = string.contains(extracted, "100")
}

pub fn unreferenced_constant_not_extracted_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

const unused_value = 42

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert False = string.contains(extracted, "unused_value")
}

// === Server Type Tests ===

pub fn detects_server_type_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Server { Server(api_key: String) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> Model(count: model.count + 1) }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = analysis.has_server
  let assert True = list.length(analysis.server_fields) == 1
  let assert Ok(field) = list.first(analysis.server_fields)
  let assert True = field.name == "api_key"
}

pub fn no_server_type_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert False = analysis.has_server
  let assert True = analysis.server_fields == []
}

pub fn server_type_not_in_extracted_client_source_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Server { Server(api_key: String, db_conn: String) }
pub type Msg { Increment }
pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert True = string.contains(extracted, "pub type Model")
  let assert False = string.contains(extracted, "Server")
  let assert False = string.contains(extracted, "api_key")
  let assert False = string.contains(extracted, "db_conn")
}

pub fn init_server_not_in_extracted_client_source_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Server { Server(key: String) }
pub type Msg { Increment }

fn init_server() { Server(key: \"secret\") }

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert False = string.contains(extracted, "init_server")
}

// === Computed Field Tests ===
// Computed fields are detected by signature: pub fn(Model) -> T
// (not view/update/init, not returning Node)

pub fn detects_computed_fields_by_signature_test() {
  let source =
    "
pub type Model { Model(items: List(Int), tax_rate: Float) }
pub type Msg { AddItem }

pub fn subtotal(model: Model) -> Int {
  0
}

pub fn total(model: Model) -> Int {
  0
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { AddItem -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.computed_fields) == 2
  let names = list.map(analysis.computed_fields, fn(c) { c.name })
  let assert True = list.contains(names, "subtotal")
  let assert True = list.contains(names, "total")
}

pub fn computed_field_return_type_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

pub fn display_count(model: Model) -> String {
  \"count\"
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  let assert True = list.length(analysis.computed_fields) == 1
  let assert Ok(field) = list.first(analysis.computed_fields)
  let assert True = field.name == "display_count"
  let assert True = field.return_type == "String"
}

pub fn computed_function_not_in_extracted_client_source_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

pub fn doubled(model: Model) -> Int {
  model.count * 2
}

pub fn view(model: Model) { model }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert False = string.contains(extracted, "fn doubled")
}

pub fn view_not_detected_as_computed_test() {
  let source =
    "
import beacon
pub type Model { Model(count: Int) }
pub type Msg { Increment }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> model }
}
pub fn view(model: Model) -> beacon.Node(Msg) { beacon.text(\"hi\") }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  // view takes Model but returns Node — should NOT be computed
  let names = list.map(analysis.computed_fields, fn(c) { c.name })
  let assert False = list.contains(names, "view")
}

pub fn private_fn_not_computed_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

fn helper(model: Model) -> Int { model.count + 1 }

pub fn update(model: Model, msg: Msg) -> Model {
  case msg { Increment -> model }
}
pub fn view(model: Model) { model }
"
  let assert Ok(analysis) = analyzer.analyze(source)
  // Private fn(Model) -> T is NOT computed (not pub)
  let assert True = analysis.computed_fields == []
}

pub fn non_computed_helper_still_extracted_test() {
  let source =
    "
pub type Model { Model(count: Int) }
pub type Msg { Increment }

fn helper(x: Int) -> Int { x + 1 }

pub fn view(model: Model) { helper(model.count) }
"
  let assert Ok(extracted) = analyzer.extract_client_source(source)
  let assert True = string.contains(extracted, "helper")
}
