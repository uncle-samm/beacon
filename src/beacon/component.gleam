/// Beacon's component system — encapsulated MVU units.
/// Each component has its own model, message type, init, update, and view.
/// Components compose via message mapping.
///
/// Reference: Lustre's element.map, Elm's Html.map, LiveView components.

import beacon/effect.{type Effect}
import beacon/element.{type Node}

/// A component definition — an encapsulated MVU unit.
/// Components have their own model, messages, and lifecycle.
pub type Component(model, msg, parent_msg) {
  Component(
    /// Initialize the component's model.
    init: fn() -> #(model, Effect(msg)),
    /// Update the component's model.
    update: fn(model, msg) -> #(model, Effect(msg)),
    /// Render the component's view.
    view: fn(model) -> Node(msg),
    /// Map component messages to parent messages.
    /// This is how parent-child communication works.
    to_parent: fn(msg) -> parent_msg,
  )
}

/// Create a new component definition.
pub fn new(
  init: fn() -> #(model, Effect(msg)),
  update: fn(model, msg) -> #(model, Effect(msg)),
  view: fn(model) -> Node(msg),
  to_parent: fn(msg) -> parent_msg,
) -> Component(model, msg, parent_msg) {
  Component(init: init, update: update, view: view, to_parent: to_parent)
}

/// Render a component, mapping its messages to the parent's message type.
/// This is the primary way to embed a component in a parent's view.
///
/// Reference: Lustre's element.map() — transforms the message type of a subtree.
pub fn render(
  component: Component(model, msg, parent_msg),
  model: model,
) -> Node(parent_msg) {
  let child_view = component.view(model)
  map_node(child_view, component.to_parent)
}

/// Map all messages in a Node tree from one type to another.
/// This is the mechanism for composing components — a child component's
/// view produces Node(child_msg), and map_node converts it to Node(parent_msg).
///
/// Reference: Lustre's element.map, Elm's Html.map.
pub fn map_node(node: Node(a), f: fn(a) -> b) -> Node(b) {
  case node {
    element.TextNode(content) -> element.TextNode(content: content)
    element.ElementNode(tag, attributes, children) ->
      element.ElementNode(
        tag: tag,
        attributes: attributes,
        children: map_children(children, f),
      )
    element.MemoNode(key, deps, child) ->
      element.MemoNode(key: key, deps: deps, child: map_node(child, f))
  }
}

/// Map all children in a list.
fn map_children(children: List(Node(a)), f: fn(a) -> b) -> List(Node(b)) {
  case children {
    [] -> []
    [first, ..rest] -> [map_node(first, f), ..map_children(rest, f)]
  }
}

/// Update a component's model and map the resulting effect.
pub fn update_component(
  component: Component(model, msg, parent_msg),
  model: model,
  msg: msg,
) -> #(model, Effect(parent_msg)) {
  let #(new_model, child_effect) = component.update(model, msg)
  let mapped_effect = effect.map(child_effect, component.to_parent)
  #(new_model, mapped_effect)
}
