import beacon/element

pub fn text_to_string_test() {
  let node = element.text("hello world")
  let assert "hello world" = element.to_string(node)
}

pub fn text_escapes_html_test() {
  let node = element.text("<script>alert('xss')</script>")
  let result = element.to_string(node)
  let assert True = does_not_contain(result, "<script>")
}

pub fn empty_element_test() {
  let node = element.el("div", [], [])
  let assert "<div></div>" = element.to_string(node)
}

pub fn element_with_text_child_test() {
  let node = element.el("p", [], [element.text("hello")])
  let assert "<p>hello</p>" = element.to_string(node)
}

pub fn element_with_attribute_test() {
  let node = element.el("div", [element.attr("class", "container")], [])
  let assert "<div class=\"container\"></div>" = element.to_string(node)
}

pub fn element_with_multiple_attributes_test() {
  let node =
    element.el(
      "div",
      [element.attr("id", "main"), element.attr("class", "active")],
      [],
    )
  let result = element.to_string(node)
  let assert True = str_contains(result, "id=\"main\"")
  let assert True = str_contains(result, "class=\"active\"")
}

pub fn nested_elements_test() {
  let node =
    element.el("div", [], [
      element.el("h1", [], [element.text("Title")]),
      element.el("p", [], [element.text("Content")]),
    ])
  let assert "<div><h1>Title</h1><p>Content</p></div>" =
    element.to_string(node)
}

pub fn void_element_test() {
  let node = element.el("br", [], [])
  let assert "<br>" = element.to_string(node)
}

pub fn void_element_input_test() {
  let node = element.el("input", [element.attr("type", "text")], [])
  let assert "<input type=\"text\">" = element.to_string(node)
}

pub fn event_attribute_renders_as_data_attr_test() {
  let node =
    element.el("button", [element.on("click", "handler_1")], [
      element.text("Click"),
    ])
  let result = element.to_string(node)
  let assert True = str_contains(result, "data-beacon-event-click")
  let assert True = str_contains(result, "handler_1")
}

pub fn attribute_escapes_quotes_test() {
  let node = element.el("div", [element.attr("title", "He said \"hi\"")], [])
  let result = element.to_string(node)
  let assert True = str_contains(result, "&quot;")
}

pub fn to_json_string_text_test() {
  let node = element.text("hello")
  let result = element.to_json_string(node)
  let assert True = str_contains(result, "\"text\"")
  let assert True = str_contains(result, "\"hello\"")
}

pub fn to_json_string_element_test() {
  let node = element.el("div", [element.attr("id", "x")], [element.text("hi")])
  let result = element.to_json_string(node)
  let assert True = str_contains(result, "\"el\"")
  let assert True = str_contains(result, "\"div\"")
  let assert True = str_contains(result, "\"hi\"")
}

// --- Helpers ---

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

fn does_not_contain(haystack: String, needle: String) -> Bool {
  case do_str_contains(haystack, needle) {
    True -> False
    False -> True
  }
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool
