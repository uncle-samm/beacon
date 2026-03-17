/// Multi-user drawing canvas — real-time collaboration.
/// Drawing is LOCAL (instant, zero traffic). On mouseup, accumulated strokes
/// are serialized and sent to the server which commits them to the shared store.
/// Other users see the strokes via PubSub broadcast — zero flicker for the drawer.

import beacon
import beacon/html
import beacon/store
import gleam/int
import gleam/list
import gleam/string

/// A single stroke segment.
pub type Stroke {
  Stroke(x1: Int, y1: Int, x2: Int, y2: Int, color: String)
}

/// Server state — committed strokes from shared store.
pub type Model {
  Model(
    /// All committed strokes from all users (read from store).
    strokes: List(Stroke),
    /// Current user's selected color.
    color: String,
  )
}

/// Client state — drawing in progress, instant feedback.
pub type Local {
  Local(
    /// Whether the user is currently drawing.
    drawing: Bool,
    /// Current cursor position.
    cursor_x: Int,
    cursor_y: Int,
    /// Strokes drawn during current drag (not yet committed).
    pending_strokes: List(Stroke),
  )
}

pub type Msg {
  // Server — commits to shared store
  FinishDrawing
  SetColor(String)
  ClearCanvas
  StrokesUpdated
  // Local — instant, zero traffic
  StartDrawing(String)
  MoveCursor(String)
}

pub fn make_init(
  stroke_store: store.ListStore(Stroke),
) -> fn() -> Model {
  fn() {
    Model(strokes: store.get_all(stroke_store, "canvas"), color: "#000000")
  }
}

pub fn init_local(_model: Model) -> Local {
  Local(drawing: False, cursor_x: 0, cursor_y: 0, pending_strokes: [])
}

pub fn make_update(
  stroke_store: store.ListStore(Stroke),
) -> fn(Model, Local, Msg) -> #(Model, Local) {
  fn(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
    case msg {
      FinishDrawing -> {
        // Commit all pending strokes at once — single broadcast, not per-stroke
        store.append_many(stroke_store, "canvas", local.pending_strokes)
        let all = list.append(model.strokes, local.pending_strokes)
        #(Model(..model, strokes: all), Local(..local, drawing: False, pending_strokes: []))
      }
      SetColor(c) ->
        #(Model(..model, color: c), local)
      ClearCanvas -> {
        store.delete_all(stroke_store, "canvas")
        #(Model(..model, strokes: []), Local(..local, pending_strokes: []))
      }
      StrokesUpdated -> {
        let strokes = store.get_all(stroke_store, "canvas")
        #(Model(..model, strokes: strokes), local)
      }
      StartDrawing(coords) -> {
        let #(x, y) = parse_coords(coords)
        #(model, Local(drawing: True, cursor_x: x, cursor_y: y, pending_strokes: []))
      }
      MoveCursor(coords) -> {
        let #(x, y) = parse_coords(coords)
        case local.drawing {
          True -> {
            let stroke = Stroke(
              x1: local.cursor_x,
              y1: local.cursor_y,
              x2: x,
              y2: y,
              color: model.color,
            )
            #(model, Local(
              ..local,
              cursor_x: x,
              cursor_y: y,
              pending_strokes: [stroke, ..local.pending_strokes],
            ))
          }
          False ->
            #(model, Local(..local, cursor_x: x, cursor_y: y))
        }
      }
    }
  }
}

/// Parse "x,y" coordinate string from mouse events.
fn parse_coords(coords: String) -> #(Int, Int) {
  case string.split(coords, ",") {
    [xs, ys] ->
      case int.parse(xs), int.parse(ys) {
        Ok(x), Ok(y) -> #(x, y)
        _, _ -> #(0, 0)
      }
    _ -> #(0, 0)
  }
}

pub fn view(model: Model, local: Local) -> beacon.Node(Msg) {
  let all_strokes = list.append(model.strokes, local.pending_strokes)
  html.div([html.style("font-family:system-ui;max-width:800px;margin:2rem auto;user-select:none")], [
    html.h1([], [html.text("Collaborative Canvas")]),
    html.p([html.style("color:#666")], [
      html.text("Draw with your mouse! Strokes: " <> int.to_string(list.length(all_strokes))),
    ]),
    // Color picker
    html.div([html.style("margin:1rem 0;display:flex;gap:8px;align-items:center")], [
      color_button("#000000", model.color),
      color_button("#ff0000", model.color),
      color_button("#0000ff", model.color),
      color_button("#00aa00", model.color),
      color_button("#ff8800", model.color),
      color_button("#8800ff", model.color),
      html.button([beacon.on_click(ClearCanvas), html.style("margin-left:auto;padding:4px 12px")], [
        html.text("Clear"),
      ]),
    ]),
    // Canvas area — SVG with separate groups for committed and pending strokes.
    // The morph algorithm only diffs children that changed — committed strokes
    // are stable (same elements), so only pending strokes cause DOM mutations.
    html.element("svg", [
      html.attribute("viewBox", "0 0 760 500"),
      html.attribute("width", "760"),
      html.attribute("height", "500"),
      html.style("border:2px solid #ccc;border-radius:8px;background:#fafafa;cursor:crosshair;display:block"),
      beacon.on_mousedown(StartDrawing),
      beacon.on_mouseup(FinishDrawing),
      beacon.on_mousemove(MoveCursor),
    ], [
      // Committed strokes (stable — morph skips unchanged children)
      html.element("g", [html.id("committed")], list.map(model.strokes, stroke_to_line)),
      // Pending strokes (changes every mousemove — only this group re-diffs)
      html.element("g", [html.id("pending")], list.map(local.pending_strokes, stroke_to_line)),
    ]),
    // Status
    html.div([html.style("margin-top:1rem;font-size:0.9rem;color:#888")], [
      html.text("Color: "),
      html.span([html.style("display:inline-block;width:20px;height:20px;background:" <> model.color <> ";border-radius:4px;vertical-align:middle")], []),
      html.text(" | " <> case local.drawing {
        True -> "Drawing at (" <> int.to_string(local.cursor_x) <> ", " <> int.to_string(local.cursor_y) <> ")"
        False -> "Click and drag to draw"
      }),
    ]),
  ])
}

fn stroke_to_line(s: Stroke) -> beacon.Node(Msg) {
  html.element("line", [
    html.attribute("x1", int.to_string(s.x1)),
    html.attribute("y1", int.to_string(s.y1)),
    html.attribute("x2", int.to_string(s.x2)),
    html.attribute("y2", int.to_string(s.y2)),
    html.attribute("stroke", s.color),
    html.attribute("stroke-width", "3"),
    html.attribute("stroke-linecap", "round"),
  ], [])
}

fn color_button(color: String, selected: String) -> beacon.Node(Msg) {
  let border = case color == selected {
    True -> "3px solid #333"
    False -> "1px solid #ccc"
  }
  html.button([
    beacon.on_click(SetColor(color)),
    html.style("width:32px;height:32px;background:" <> color <> ";border:" <> border <> ";border-radius:4px;cursor:pointer"),
  ], [])
}

pub fn main() {
  let stroke_store = store.new_list("canvas_strokes")

  beacon.app_with_local(make_init(stroke_store), init_local, make_update(stroke_store), view)
  |> beacon.title("Collaborative Canvas")
  |> beacon.subscriptions(fn(_model) { ["store:canvas_strokes"] })
  |> beacon.on_notify(fn(_topic) { StrokesUpdated })
  |> beacon.start(8080)
}

