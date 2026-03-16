import beacon/build/analyzer
import gleam/list

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
