import beacon/element
import beacon/html

pub fn div_matches_element_el_test() {
  let a = html.div([html.class("x")], [html.text("hi")])
  let b = element.el("div", [element.attr("class", "x")], [element.text("hi")])
  let assert True = element.to_string(a) == element.to_string(b)
}

pub fn button_test() {
  let node = html.button([html.id("btn")], [html.text("Click")])
  let s = element.to_string(node)
  let assert True = str_contains(s, "<button")
  let assert True = str_contains(s, "id=\"btn\"")
  let assert True = str_contains(s, "Click")
}

pub fn input_void_test() {
  let node = html.input([html.type_("text"), html.placeholder("Name...")])
  let s = element.to_string(node)
  let assert True = str_contains(s, "<input")
  let assert True = str_contains(s, "type=\"text\"")
  // Void — no closing tag
  let assert False = str_contains(s, "</input>")
}

pub fn br_test() {
  let assert "<br>" = element.to_string(html.br())
}

pub fn nested_test() {
  let node =
    html.div([], [
      html.h1([], [html.text("Title")]),
      html.p([], [html.text("Body")]),
    ])
  let assert "<div><h1>Title</h1><p>Body</p></div>" = element.to_string(node)
}

pub fn ul_li_test() {
  let node =
    html.ul([], [
      html.li([], [html.text("a")]),
      html.li([], [html.text("b")]),
    ])
  let s = element.to_string(node)
  let assert True = str_contains(s, "<ul>")
  let assert True = str_contains(s, "<li>a</li>")
}

pub fn attribute_shortcuts_test() {
  let node =
    html.a([html.href("/about"), html.class("link")], [html.text("About")])
  let s = element.to_string(node)
  let assert True = str_contains(s, "href=\"/about\"")
  let assert True = str_contains(s, "class=\"link\"")
}

pub fn img_void_test() {
  let node = html.img([html.src_("/logo.png")])
  let s = element.to_string(node)
  let assert True = str_contains(s, "<img")
  let assert True = str_contains(s, "src=\"/logo.png\"")
}

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool
