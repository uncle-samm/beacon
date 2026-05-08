import beacon/element

/// Mount a client-owned DOM island.
/// Beacon keeps this wrapper node's attributes up to date but never morphs its children.
pub fn mount(
  id: String,
  hook: String,
  attrs: List(element.Attr),
) -> element.Node(msg) {
  element.keyed(
    id,
    element.el(
      "div",
      [
        element.attr("data-beacon-island", id),
        element.attr("data-beacon-hook", hook),
        element.attr("data-beacon-preserve-children", "true"),
        ..attrs
      ],
      [],
    ),
  )
}
