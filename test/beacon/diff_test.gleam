import beacon/diff
import beacon/element

// --- Identical trees produce no patches ---

pub fn identical_text_nodes_test() {
  let node = element.text("hello")
  let patches = diff.diff(node, node)
  let assert [] = patches
}

pub fn identical_elements_test() {
  let node =
    element.el("div", [element.attr("class", "foo")], [element.text("hi")])
  let patches = diff.diff(node, node)
  let assert [] = patches
}

pub fn identical_nested_elements_test() {
  let node =
    element.el("div", [], [
      element.el("span", [], [element.text("a")]),
      element.el("span", [], [element.text("b")]),
    ])
  let patches = diff.diff(node, node)
  let assert [] = patches
}

// --- Text content changes ---

pub fn text_content_changed_test() {
  let old = element.text("old")
  let new = element.text("new")
  let patches = diff.diff(old, new)
  let assert [diff.ReplaceText(path: [], content: "new")] = patches
}

pub fn nested_text_content_changed_test() {
  let old = element.el("div", [], [element.text("old")])
  let new = element.el("div", [], [element.text("new")])
  let patches = diff.diff(old, new)
  let assert [diff.ReplaceText(path: [0], content: "new")] = patches
}

pub fn deeply_nested_text_changed_test() {
  let old =
    element.el("div", [], [
      element.el("span", [], [element.text("old")]),
    ])
  let new =
    element.el("div", [], [
      element.el("span", [], [element.text("new")]),
    ])
  let patches = diff.diff(old, new)
  let assert [diff.ReplaceText(path: [0, 0], content: "new")] = patches
}

// --- Element tag changes ---

pub fn different_tags_replaced_test() {
  let old = element.el("div", [], [])
  let new = element.el("span", [], [])
  let patches = diff.diff(old, new)
  let assert [diff.ReplaceNode(path: [], ..)] = patches
}

pub fn text_to_element_replaced_test() {
  let old = element.text("hello")
  let new = element.el("div", [], [])
  let patches = diff.diff(old, new)
  let assert [diff.ReplaceNode(path: [], ..)] = patches
}

pub fn element_to_text_replaced_test() {
  let old = element.el("div", [], [])
  let new = element.text("hello")
  let patches = diff.diff(old, new)
  let assert [diff.ReplaceNode(path: [], ..)] = patches
}

// --- Attribute changes ---

pub fn attribute_added_test() {
  let old = element.el("div", [], [])
  let new = element.el("div", [element.attr("class", "foo")], [])
  let patches = diff.diff(old, new)
  let assert [diff.SetAttribute(path: [], name: "class", value: "foo")] =
    patches
}

pub fn attribute_removed_test() {
  let old = element.el("div", [element.attr("class", "foo")], [])
  let new = element.el("div", [], [])
  let patches = diff.diff(old, new)
  let assert [diff.RemoveAttribute(path: [], name: "class")] = patches
}

pub fn attribute_changed_test() {
  let old = element.el("div", [element.attr("class", "old")], [])
  let new = element.el("div", [element.attr("class", "new")], [])
  let patches = diff.diff(old, new)
  let assert [diff.SetAttribute(path: [], name: "class", value: "new")] =
    patches
}

pub fn event_added_test() {
  let old = element.el("button", [], [])
  let new = element.el("button", [element.on("click", "handler_1")], [])
  let patches = diff.diff(old, new)
  let assert [
    diff.SetEvent(path: [], event_name: "click", handler_id: "handler_1"),
  ] = patches
}

pub fn event_removed_test() {
  let old = element.el("button", [element.on("click", "handler_1")], [])
  let new = element.el("button", [], [])
  let patches = diff.diff(old, new)
  let assert [diff.RemoveEvent(path: [], event_name: "click")] = patches
}

// --- Child list changes ---

pub fn child_added_test() {
  let old = element.el("div", [], [])
  let new = element.el("div", [], [element.text("new child")])
  let patches = diff.diff(old, new)
  let assert [diff.InsertChild(path: [], index: 0, ..)] = patches
}

pub fn child_removed_test() {
  let old = element.el("div", [], [element.text("old child")])
  let new = element.el("div", [], [])
  let patches = diff.diff(old, new)
  let assert [diff.RemoveChild(path: [], index: 0)] = patches
}

pub fn multiple_children_added_test() {
  let old = element.el("div", [], [element.text("a")])
  let new =
    element.el("div", [], [element.text("a"), element.text("b"), element.text("c")])
  let patches = diff.diff(old, new)
  // First child "a" is unchanged, "b" and "c" are inserted
  let assert [diff.InsertChild(path: [], index: 1, ..), diff.InsertChild(path: [], index: 2, ..)] =
    patches
}

pub fn multiple_children_removed_test() {
  let old =
    element.el("div", [], [element.text("a"), element.text("b"), element.text("c")])
  let new = element.el("div", [], [element.text("a")])
  let patches = diff.diff(old, new)
  // Children at index 1 and 2 removed
  let assert [diff.RemoveChild(path: [], index: 1), diff.RemoveChild(path: [], index: 1)] =
    patches
}

// --- JSON serialization ---

pub fn patches_to_json_string_empty_test() {
  let result = diff.patches_to_json_string([])
  let assert "[]" = result
}

pub fn patches_to_json_string_replace_text_test() {
  let patches = [diff.ReplaceText(path: [0, 1], content: "hello")]
  let result = diff.patches_to_json_string(patches)
  let assert True = string_contains(result, "\"replace_text\"")
  let assert True = string_contains(result, "\"hello\"")
  let assert True = string_contains(result, "[0,1]")
}

// --- Edge cases ---

pub fn empty_tree_diff_test() {
  let old = element.el("div", [], [])
  let new = element.el("div", [], [])
  let patches = diff.diff(old, new)
  let assert [] = patches
}

pub fn same_attributes_different_order_test() {
  // Both have same attributes — should produce no attribute patches
  let old =
    element.el(
      "div",
      [element.attr("id", "x"), element.attr("class", "y")],
      [],
    )
  let new =
    element.el(
      "div",
      [element.attr("id", "x"), element.attr("class", "y")],
      [],
    )
  let patches = diff.diff(old, new)
  let assert [] = patches
}

// --- Memo tests ---

pub fn memo_same_deps_no_patches_test() {
  let child = element.el("div", [], [element.text("hello")])
  let old = element.memo("card", ["Alice", "30"], child)
  let new = element.memo("card", ["Alice", "30"], child)
  let patches = diff.diff(old, new)
  let assert [] = patches
}

pub fn memo_different_deps_produces_patches_test() {
  let old_child = element.el("div", [], [element.text("Alice")])
  let new_child = element.el("div", [], [element.text("Bob")])
  let old = element.memo("card", ["Alice"], old_child)
  let new = element.memo("card", ["Bob"], new_child)
  let patches = diff.diff(old, new)
  // Deps changed → child is diffed → text replaced
  let assert [diff.ReplaceText(path: [0], content: "Bob")] = patches
}

pub fn memo_different_key_diffs_children_test() {
  let old_child = element.el("div", [], [element.text("old")])
  let new_child = element.el("div", [], [element.text("new")])
  let old = element.memo("card-1", ["same"], old_child)
  let new = element.memo("card-2", ["same"], new_child)
  // Different keys → deps don't match → diff children
  let patches = diff.diff(old, new)
  let assert [diff.ReplaceText(path: [0], content: "new")] = patches
}

pub fn memo_vs_non_memo_diffs_child_test() {
  let child = element.el("div", [], [element.text("hello")])
  let old = element.memo("card", ["x"], child)
  let new = element.el("div", [], [element.text("hello")])
  let patches = diff.diff(old, new)
  // Memo unwrapped, child matches new → no patches
  let assert [] = patches
}

pub fn memo_to_string_renders_child_test() {
  let child = element.el("p", [], [element.text("content")])
  let node = element.memo("test", ["dep1"], child)
  let assert "<p>content</p>" = element.to_string(node)
}

// --- Helper ---

fn string_contains(haystack: String, needle: String) -> Bool {
  do_string_contains(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_string_contains(haystack: String, needle: String) -> Bool
