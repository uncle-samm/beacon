# HTML Elements Reference

Import: `import beacon/html` for elements, `import beacon` for event handlers.

## Elements

All take `(attrs: List(Attr), children: List(Node(msg)))`.

**Block:** `div`, `span`, `p`, `h1`-`h6`, `nav`, `header`, `footer`, `main`, `section`, `article`, `aside`

**Interactive:** `button`, `a`, `form`, `label`, `textarea`, `select`, `option`

**Lists:** `ul`, `ol`, `li`

**Table:** `table`, `thead`, `tbody`, `tr`, `td`, `th`

**Inline:** `strong`, `em`, `pre`, `code`

**Void (no children):** `input(attrs)`, `br()`, `hr()`, `img(attrs)`

**Custom:** `html.element("canvas", attrs, children)`

**Text:** `html.text("content")`

## Attribute Helpers

| Function | HTML |
|----------|------|
| `html.class("x")` | `class="x"` |
| `html.id("x")` | `id="x"` |
| `html.type_("text")` | `type="text"` |
| `html.value("x")` | `value="x"` |
| `html.placeholder("x")` | `placeholder="x"` |
| `html.href("/about")` | `href="/about"` |
| `html.src_("/img.png")` | `src="/img.png"` |
| `html.name("field")` | `name="field"` |
| `html.style("color:red")` | `style="color:red"` |
| `html.disabled()` | `disabled="true"` |
| `html.checked()` | `checked="true"` |
| `html.attribute("k","v")` | `k="v"` (custom) |

## Event Handlers

Defined in `beacon` (not `beacon/html`):

| Function | Event | Callback |
|----------|-------|----------|
| `on_click(Msg)` | click | Simple message |
| `on_input(fn(String) -> Msg)` | input | Receives value |
| `on_submit(Msg)` | submit | Simple message |
| `on_change(fn(String) -> Msg)` | change | Receives value |
| `on_keydown(fn(String) -> Msg)` | keydown | Receives key name |
| `on_mousedown(fn(String) -> Msg)` | mousedown | Receives "x,y" |
| `on_mouseup(Msg)` | mouseup | Simple message |
| `on_mousemove(fn(String) -> Msg)` | mousemove | Receives "x,y" |
| `on_dragstart(fn(String) -> Msg)` | dragstart | Receives drag-id |
| `on_dragover(Msg)` | dragover | Simple (preventDefault) |
| `on_drop(fn(String) -> Msg)` | drop | Receives drag-id |

## Special Elements

| Function | Description |
|----------|-------------|
| `element.none()` | Returns an empty node that renders nothing |
| `element.raw_html(html)` | Injects a raw HTML string without escaping |

**`element.none()`** is used for conditional rendering:

```gleam
case show {
  True -> element.text("visible")
  False -> element.none()
}
```

**`element.raw_html(html)`** injects pre-sanitized HTML directly into the DOM. **WARNING:** the caller must sanitize the input to prevent XSS -- this function performs no escaping. Use it for content that has already been sanitized, such as rendered markdown output.

## Example: Login Form

```gleam
fn view(model: Model) -> beacon.Node(Msg) {
  html.form([beacon.on_submit(Submit)], [
    html.label([], [html.text("Email")]),
    html.input([html.type_("email"), beacon.on_input(SetEmail)]),
    html.label([], [html.text("Password")]),
    html.input([html.type_("password"), beacon.on_input(SetPassword)]),
    html.button([html.type_("submit")], [html.text("Log in")]),
  ])
}
```
