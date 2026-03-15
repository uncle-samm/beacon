/// Beacon's element type for representing virtual DOM trees.
/// Simpler than Lustre's Element — focused on the common cases needed
/// for server-rendered diffing.
///
/// We also provide conversion from Lustre's Element type so users can
/// use Lustre's html helpers (html.div, html.button, etc.) to build views
/// and Beacon handles the diffing.
///
/// Reference: Lustre vdom/vnode.gleam, Elm's Html type.

import gleam/json
import gleam/list
import gleam/string_tree.{type StringTree}

/// A node in the virtual DOM tree.
pub type Node(msg) {
  /// A text node with string content.
  TextNode(content: String)
  /// An HTML element with tag, attributes, and children.
  ElementNode(
    tag: String,
    attributes: List(Attr),
    children: List(Node(msg)),
  )
  /// A memoized node that skips re-rendering when dependencies haven't changed.
  /// The `key` is a unique identifier, `deps` are the dependency values
  /// (compared for equality), and `child` is the rendered output.
  /// Reference: Elm's Html.Lazy, Lustre's memo.
  MemoNode(key: String, deps: List(String), child: Node(msg))
}

/// An HTML attribute (key-value pair).
/// Events are stored separately with their handler path.
pub type Attr {
  /// A regular HTML attribute like class="foo" or id="bar".
  HtmlAttr(name: String, value: String)
  /// An event handler like on_click. The value is the event name
  /// that gets sent back to the server.
  EventAttr(event_name: String, handler_id: String)
}

/// Convert a Node tree to an HTML string for SSR.
pub fn to_string(node: Node(msg)) -> String {
  to_string_tree(node)
  |> string_tree.to_string
}

/// Convert a Node tree to a StringTree (efficient string building).
pub fn to_string_tree(node: Node(msg)) -> StringTree {
  case node {
    TextNode(content) -> {
      string_tree.from_string(escape_html(content))
    }
    MemoNode(_key, _deps, child) -> {
      // Memo is transparent for rendering — just render the child
      to_string_tree(child)
    }
    ElementNode(tag, attributes, children) -> {
      let open_tag =
        string_tree.from_string("<")
        |> string_tree.append(tag)
      let with_attrs = render_attributes(open_tag, attributes)
      case is_void_element(tag) {
        True ->
          with_attrs
          |> string_tree.append(">")
        False -> {
          let children_html =
            list.fold(children, string_tree.new(), fn(acc, child) {
              string_tree.append_tree(acc, to_string_tree(child))
            })
          with_attrs
          |> string_tree.append(">")
          |> string_tree.append_tree(children_html)
          |> string_tree.append("</")
          |> string_tree.append(tag)
          |> string_tree.append(">")
        }
      }
    }
  }
}

/// Convert a Node tree to a JSON value for wire transport.
pub fn to_json(node: Node(msg)) -> json.Json {
  case node {
    TextNode(content) ->
      json.object([
        #("t", json.string("text")),
        #("c", json.string(content)),
      ])
    MemoNode(_key, _deps, child) ->
      // Memo is transparent for JSON — serialize the child
      to_json(child)
    ElementNode(tag, attributes, children) ->
      json.object([
        #("t", json.string("el")),
        #("tag", json.string(tag)),
        #("a", json.array(attributes, attr_to_json)),
        #("ch", json.array(children, to_json)),
      ])
  }
}

/// Serialize a Node tree to a JSON string.
pub fn to_json_string(node: Node(msg)) -> String {
  to_json(node) |> json.to_string
}

// --- Constructors ---

/// Create a text node.
pub fn text(content: String) -> Node(msg) {
  TextNode(content: content)
}

/// Create an element node.
pub fn el(
  tag: String,
  attributes: List(Attr),
  children: List(Node(msg)),
) -> Node(msg) {
  ElementNode(tag: tag, attributes: attributes, children: children)
}

/// Create an HTML attribute.
pub fn attr(name: String, value: String) -> Attr {
  HtmlAttr(name: name, value: value)
}

/// Create an event handler attribute.
pub fn on(event_name: String, handler_id: String) -> Attr {
  EventAttr(event_name: event_name, handler_id: handler_id)
}

/// Create a memoized node. The diff engine will skip re-diffing this subtree
/// when all dependency values are equal to the previous render.
/// `key` is a unique identifier, `deps` are string values to compare,
/// and `child` is the view function result.
///
/// Example:
/// ```gleam
/// element.memo("user-card", [model.name, int.to_string(model.age)],
///   element.el("div", [], [element.text(model.name)])
/// )
/// ```
/// Reference: Elm's Html.Lazy, Lustre's memo.
pub fn memo(
  key: String,
  deps: List(String),
  child: Node(msg),
) -> Node(msg) {
  MemoNode(key: key, deps: deps, child: child)
}

// --- Internal helpers ---

fn attr_to_json(attribute: Attr) -> json.Json {
  case attribute {
    HtmlAttr(name, value) ->
      json.object([
        #("t", json.string("attr")),
        #("n", json.string(name)),
        #("v", json.string(value)),
      ])
    EventAttr(event_name, handler_id) ->
      json.object([
        #("t", json.string("event")),
        #("n", json.string(event_name)),
        #("h", json.string(handler_id)),
      ])
  }
}

fn render_attributes(tree: StringTree, attributes: List(Attr)) -> StringTree {
  list.fold(attributes, tree, fn(acc, attribute) {
    case attribute {
      HtmlAttr(name, value) ->
        acc
        |> string_tree.append(" ")
        |> string_tree.append(name)
        |> string_tree.append("=\"")
        |> string_tree.append(escape_attr(value))
        |> string_tree.append("\"")
      EventAttr(event_name, handler_id) ->
        acc
        |> string_tree.append(" data-beacon-event-")
        |> string_tree.append(event_name)
        |> string_tree.append("=\"")
        |> string_tree.append(handler_id)
        |> string_tree.append("\"")
    }
  })
}

fn is_void_element(tag: String) -> Bool {
  case tag {
    "area" | "base" | "br" | "col" | "embed" | "hr" | "img" | "input"
    | "link" | "meta" | "param" | "source" | "track" | "wbr" -> True
    _ -> False
  }
}

fn escape_html(text: String) -> String {
  text
  |> do_replace("&", "&amp;")
  |> do_replace("<", "&lt;")
  |> do_replace(">", "&gt;")
}

fn escape_attr(text: String) -> String {
  text
  |> do_replace("&", "&amp;")
  |> do_replace("\"", "&quot;")
  |> do_replace("<", "&lt;")
  |> do_replace(">", "&gt;")
}

@external(erlang, "beacon_element_ffi", "string_replace")
fn do_replace(subject: String, pattern: String, replacement: String) -> String
