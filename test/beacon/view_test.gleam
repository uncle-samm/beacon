import beacon/element
import beacon/template/rendered
import beacon/view

// --- Basic conversion tests ---

pub fn text_node_is_dynamic_test() {
  let node = element.text("hello")
  let r = view.render(node)
  // Static: ["", ""] (before and after the dynamic), Dynamic: ["hello"]
  let assert ["", ""] = r.statics
  let assert ["hello"] = r.dynamics
}

pub fn empty_element_all_static_test() {
  let node = element.el("div", [], [])
  let r = view.render(node)
  let assert ["<div></div>"] = r.statics
  let assert [] = r.dynamics
}

pub fn element_with_text_child_test() {
  let node = element.el("div", [], [element.text("hello")])
  let r = view.render(node)
  let assert ["<div>", "</div>"] = r.statics
  let assert ["hello"] = r.dynamics
}

pub fn element_with_attribute_test() {
  let node = element.el("div", [element.attr("class", "box")], [])
  let r = view.render(node)
  // Attribute values are DYNAMIC — so the attribute name/quotes are static
  let assert ["<div class=\"", "\"></div>"] = r.statics
  let assert ["box"] = r.dynamics
}

pub fn element_with_event_test() {
  let node =
    element.el("button", [element.on("click", "inc")], [element.text("+")])
  let r = view.render(node)
  let assert ["<button data-beacon-event-click=\"inc\">", "</button>"] =
    r.statics
  let assert ["+"] = r.dynamics
}

pub fn nested_elements_test() {
  let node =
    element.el("div", [], [
      element.el("h1", [], [element.text("Title")]),
      element.el("p", [], [element.text("Body")]),
    ])
  let r = view.render(node)
  let assert ["<div><h1>", "</h1><p>", "</p></div>"] = r.statics
  let assert ["Title", "Body"] = r.dynamics
}

pub fn multiple_text_nodes_test() {
  let node =
    element.el("p", [], [
      element.text("Count: "),
      element.text("42"),
    ])
  let r = view.render(node)
  let assert ["<p>", "", "</p>"] = r.statics
  let assert ["Count: ", "42"] = r.dynamics
}

pub fn void_element_test() {
  let node = element.el("br", [], [])
  let r = view.render(node)
  let assert ["<br>"] = r.statics
  let assert [] = r.dynamics
}

pub fn void_element_with_attrs_test() {
  let node =
    element.el("input", [element.attr("type", "text")], [])
  let r = view.render(node)
  let assert ["<input type=\"", "\">"] = r.statics
  let assert ["text"] = r.dynamics
}

pub fn memo_node_transparent_test() {
  let child = element.el("span", [], [element.text("cached")])
  let node = element.memo("k", ["d"], child)
  let r = view.render(node)
  let assert ["<span>", "</span>"] = r.statics
  let assert ["cached"] = r.dynamics
}

// --- to_html reconstruction test ---

pub fn rendered_to_html_matches_element_to_string_test() {
  let node =
    element.el("div", [element.attr("class", "counter")], [
      element.el("h1", [], [element.text("Beacon Counter")]),
      element.el("p", [], [element.text("Count: 0")]),
      element.el(
        "button",
        [element.on("click", "dec")],
        [element.text("-")],
      ),
      element.el(
        "button",
        [element.on("click", "inc")],
        [element.text("+")],
      ),
    ])
  let r = view.render(node)
  let html_from_rendered = rendered.to_html(r)
  let html_from_element = element.to_string(node)
  let assert True = html_from_rendered == html_from_element
}

// --- Fingerprint stability test ---

pub fn same_structure_same_fingerprint_test() {
  let node1 =
    element.el("div", [], [element.text("A")])
  let node2 =
    element.el("div", [], [element.text("B")])
  let r1 = view.render(node1)
  let r2 = view.render(node2)
  // Same template structure → same fingerprint
  let assert True = r1.fingerprint == r2.fingerprint
  // But different dynamics
  let assert ["A"] = r1.dynamics
  let assert ["B"] = r2.dynamics
}

pub fn different_structure_different_fingerprint_test() {
  let node1 = element.el("div", [], [element.text("A")])
  let node2 = element.el("span", [], [element.text("A")])
  let r1 = view.render(node1)
  let r2 = view.render(node2)
  let assert True = r1.fingerprint != r2.fingerprint
}

// --- Diff integration test ---

pub fn rendered_diff_only_changed_dynamics_test() {
  let node_old =
    element.el("div", [], [
      element.el("h1", [], [element.text("Title")]),
      element.el("p", [], [element.text("Old body")]),
    ])
  let node_new =
    element.el("div", [], [
      element.el("h1", [], [element.text("Title")]),
      element.el("p", [], [element.text("New body")]),
    ])
  let r_old = view.render(node_old)
  let r_new = view.render(node_new)
  let diff = rendered.diff(r_old, r_new)
  // Only dynamic index 1 changed ("Old body" → "New body")
  // Dynamic 0 is "Title" (unchanged)
  let assert rendered.DynamicDiff(changes: [#(1, "New body")]) = diff
}

pub fn rendered_diff_no_change_test() {
  let node = element.el("div", [], [element.text("same")])
  let r = view.render(node)
  let diff = rendered.diff(r, r)
  let assert rendered.NoDiff = diff
}

pub fn rendered_diff_json_compact_test() {
  let node_old = element.el("div", [], [element.text("old")])
  let node_new = element.el("div", [], [element.text("new")])
  let r_old = view.render(node_old)
  let r_new = view.render(node_new)
  let diff = rendered.diff(r_old, r_new)
  let json_str = rendered.diff_to_json_string(diff)
  // Should be compact: {"0":"new"}
  let assert True = str_contains(json_str, "\"0\":\"new\"")
  // Should NOT contain statics (same fingerprint)
  let assert False = str_contains(json_str, "\"s\":")
}

// --- Helper ---

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool
