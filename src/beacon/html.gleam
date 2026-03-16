/// HTML element helpers — shorthand for building views.
/// Instead of `element.el("div", [element.attr("class", "x")], [...])`,
/// write `html.div([html.class("x")], [...])`.

import beacon/element.{type Attr, type Node}

// === Text ===

/// Create a text node.
pub fn text(content: String) -> Node(msg) {
  element.text(content)
}

// === Block elements ===

pub fn div(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("div", attrs, children)
}

pub fn span(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("span", attrs, children)
}

pub fn p(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("p", attrs, children)
}

pub fn h1(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("h1", attrs, children)
}

pub fn h2(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("h2", attrs, children)
}

pub fn h3(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("h3", attrs, children)
}

pub fn h4(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("h4", attrs, children)
}

pub fn h5(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("h5", attrs, children)
}

pub fn h6(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("h6", attrs, children)
}

// === Semantic sections ===

pub fn nav(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("nav", attrs, children)
}

pub fn header(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("header", attrs, children)
}

pub fn footer(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("footer", attrs, children)
}

pub fn main(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("main", attrs, children)
}

pub fn section(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("section", attrs, children)
}

pub fn article(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("article", attrs, children)
}

pub fn aside(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("aside", attrs, children)
}

// === Interactive ===

pub fn button(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("button", attrs, children)
}

pub fn a(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("a", attrs, children)
}

pub fn form(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("form", attrs, children)
}

pub fn label(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("label", attrs, children)
}

pub fn textarea(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("textarea", attrs, children)
}

pub fn select(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("select", attrs, children)
}

pub fn option(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("option", attrs, children)
}

// === Void elements (no children) ===

pub fn input(attrs: List(Attr)) -> Node(msg) {
  element.el("input", attrs, [])
}

pub fn br() -> Node(msg) {
  element.el("br", [], [])
}

pub fn hr() -> Node(msg) {
  element.el("hr", [], [])
}

pub fn img(attrs: List(Attr)) -> Node(msg) {
  element.el("img", attrs, [])
}

// === Lists ===

pub fn ul(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("ul", attrs, children)
}

pub fn ol(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("ol", attrs, children)
}

pub fn li(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("li", attrs, children)
}

// === Table ===

pub fn table(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("table", attrs, children)
}

pub fn thead(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("thead", attrs, children)
}

pub fn tbody(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("tbody", attrs, children)
}

pub fn tr(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("tr", attrs, children)
}

pub fn td(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("td", attrs, children)
}

pub fn th(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("th", attrs, children)
}

// === Inline text ===

pub fn strong(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("strong", attrs, children)
}

pub fn em(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("em", attrs, children)
}

pub fn pre(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("pre", attrs, children)
}

pub fn code(attrs: List(Attr), children: List(Node(msg))) -> Node(msg) {
  element.el("code", attrs, children)
}

// === Attribute shortcuts ===

pub fn class(name: String) -> Attr {
  element.attr("class", name)
}

pub fn id(name: String) -> Attr {
  element.attr("id", name)
}

pub fn type_(name: String) -> Attr {
  element.attr("type", name)
}

pub fn value(val: String) -> Attr {
  element.attr("value", val)
}

pub fn placeholder(text: String) -> Attr {
  element.attr("placeholder", text)
}

pub fn href(url: String) -> Attr {
  element.attr("href", url)
}

pub fn src_(url: String) -> Attr {
  element.attr("src", url)
}

pub fn name(n: String) -> Attr {
  element.attr("name", n)
}

pub fn style(css: String) -> Attr {
  element.attr("style", css)
}

pub fn disabled() -> Attr {
  element.attr("disabled", "true")
}

pub fn checked() -> Attr {
  element.attr("checked", "true")
}
