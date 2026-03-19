# Components

Components are encapsulated MVU units with their own model, message type, and lifecycle.

## The Component Type

```gleam
pub type Component(model, msg, parent_msg) {
  Component(
    init: fn() -> #(model, Effect(msg)),
    update: fn(model, msg) -> #(model, Effect(msg)),
    view: fn(model) -> Node(msg),
    to_parent: fn(msg) -> parent_msg,
  )
}
```

## Creating a Component

Use `component.new(init, update, view, to_parent)`:

```gleam
let counter = component.new(
  init: fn() { #(0, effect.none()) },
  update: fn(count, msg) { case msg {
    Increment -> #(count + 1, effect.none())
    Decrement -> #(count - 1, effect.none())
  }},
  view: fn(count) { html.div([], [
    html.button([beacon.on_click(Decrement)], [html.text("-")]),
    html.button([beacon.on_click(Increment)], [html.text("+")]),
  ])},
  to_parent: fn(msg) { CounterMsg(msg) },
)
```

## Rendering and Updating

Use `component.render(comp, model)` in the parent's view -- it maps messages through `to_parent`:

```gleam
fn view(model: ParentModel) -> Node(ParentMsg) {
  html.div([], [component.render(counter, model.counter_state)])
}
```

Use `component.update_component` in the parent's update to delegate:

```gleam
case msg {
  CounterMsg(child_msg) -> {
    let #(new_counter, eff) =
      component.update_component(counter, model.counter_state, child_msg)
    #(ParentModel(..model, counter_state: new_counter), eff)
  }
}
```
## Message Mapping

`component.map_node(node, fn)` transforms messages in a `Node` tree. This is the mechanism underlying `render` -- equivalent to Lustre's `element.map`.
