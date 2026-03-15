import beacon/component
import beacon/effect
import beacon/element

// --- Child component: a simple counter ---

pub type ChildModel {
  ChildModel(count: Int)
}

pub type ChildMsg {
  ChildIncrement
  ChildDecrement
}

pub type ParentMsg {
  CounterMsg(ChildMsg)
  OtherParentAction
}

fn child_init() -> #(ChildModel, effect.Effect(ChildMsg)) {
  #(ChildModel(count: 0), effect.none())
}

fn child_update(
  model: ChildModel,
  msg: ChildMsg,
) -> #(ChildModel, effect.Effect(ChildMsg)) {
  case msg {
    ChildIncrement -> #(ChildModel(count: model.count + 1), effect.none())
    ChildDecrement -> #(ChildModel(count: model.count - 1), effect.none())
  }
}

fn child_view(model: ChildModel) -> element.Node(ChildMsg) {
  element.el("div", [element.attr("class", "counter")], [
    element.el(
      "button",
      [element.on("click", "child_dec")],
      [element.text("-")],
    ),
    element.text(int_str(model.count)),
    element.el(
      "button",
      [element.on("click", "child_inc")],
      [element.text("+")],
    ),
  ])
}

fn counter_component() -> component.Component(ChildModel, ChildMsg, ParentMsg) {
  component.new(child_init, child_update, child_view, CounterMsg)
}

// --- Tests ---

pub fn component_creation_test() {
  let _comp = counter_component()
}

pub fn render_component_test() {
  let comp = counter_component()
  let #(model, _effects) = comp.init()
  let node = component.render(comp, model)
  // Should produce a Node(ParentMsg) — the message type is mapped
  let html = element.to_string(node)
  let assert True = str_contains(html, "counter")
  let assert True = str_contains(html, "-")
  let assert True = str_contains(html, "+")
}

pub fn map_node_preserves_structure_test() {
  let child_node = element.el("div", [], [element.text("hello")])
  let parent_node = component.map_node(child_node, CounterMsg)
  let assert "<div>hello</div>" = element.to_string(parent_node)
}

pub fn map_node_preserves_attributes_test() {
  let child_node =
    element.el("div", [element.attr("class", "test")], [])
  let parent_node = component.map_node(child_node, CounterMsg)
  let html = element.to_string(parent_node)
  let assert True = str_contains(html, "class=\"test\"")
}

pub fn map_node_preserves_memo_test() {
  let child = element.el("span", [], [element.text("cached")])
  let memo_node = element.memo("key", ["dep1"], child)
  let mapped = component.map_node(memo_node, CounterMsg)
  let assert "<span>cached</span>" = element.to_string(mapped)
}

pub fn update_component_test() {
  let comp = counter_component()
  let #(model, _) = comp.init()
  let #(new_model, _effect) =
    component.update_component(comp, model, ChildIncrement)
  let assert 1 = new_model.count
}

pub fn update_component_maps_effect_test() {
  // Create a component where update produces an effect
  let comp =
    component.new(
      child_init,
      fn(_model, _msg) {
        #(
          ChildModel(count: 99),
          effect.from(fn(dispatch) { dispatch(ChildIncrement) }),
        )
      },
      child_view,
      CounterMsg,
    )
  let #(model, _) = comp.init()
  let #(new_model, mapped_effect) =
    component.update_component(comp, model, ChildIncrement)
  let assert 99 = new_model.count
  // The effect should be mapped — it's not None
  let assert False = effect.is_none(mapped_effect)
}

pub fn nested_render_test() {
  let comp = counter_component()
  let #(child_model, _) = comp.init()

  // Parent view embeds the component
  let parent_view =
    element.el("main", [], [
      element.el("h1", [], [element.text("Parent")]),
      component.render(comp, child_model),
    ])

  let html = element.to_string(parent_view)
  let assert True = str_contains(html, "<main>")
  let assert True = str_contains(html, "Parent")
  let assert True = str_contains(html, "counter")
}

// --- Helpers ---

fn int_str(n: Int) -> String {
  do_int_str(n)
}

@external(erlang, "erlang", "integer_to_binary")
fn do_int_str(n: Int) -> String

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool
