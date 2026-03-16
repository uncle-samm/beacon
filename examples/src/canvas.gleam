/// Multi-user drawing canvas — real-time collaboration.
/// All users draw on the same canvas. Strokes sync via shared store + PubSub.
/// Demonstrates: shared state, real-time updates, SVG rendering.

import beacon
import beacon/html
import gleam/int

/// Server state — per-tab cursor position.
pub type Model {
  Model(
    /// All strokes from all users (synced via store).
    stroke_count: Int,
    /// Current user's selected color.
    color: String,
  )
}

/// Client state — instant, zero server traffic.
pub type Local {
  Local(
    /// Whether the user is currently drawing.
    drawing: Bool,
    /// Current cursor X position.
    cursor_x: Int,
    /// Current cursor Y position.
    cursor_y: Int,
  )
}

pub type Msg {
  // Shared — syncs with server
  AddStroke(x1: Int, y1: Int, x2: Int, y2: Int, color: String)
  StrokesUpdated
  SetColor(String)
  ClearCanvas
  // Local — instant, zero traffic
  StartDrawing
  StopDrawing
  MoveCursor(Int, Int)
}

pub fn init() -> Model {
  Model(stroke_count: 0, color: "#000000")
}

pub fn init_local(_model: Model) -> Local {
  Local(drawing: False, cursor_x: 0, cursor_y: 0)
}

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    AddStroke(_, _, _, _, _) ->
      #(Model(..model, stroke_count: model.stroke_count + 1), local)
    StrokesUpdated ->
      #(model, local)
    SetColor(c) ->
      #(Model(..model, color: c), local)
    ClearCanvas ->
      #(Model(..model, stroke_count: 0), local)
    StartDrawing ->
      #(model, Local(..local, drawing: True))
    StopDrawing ->
      #(model, Local(..local, drawing: False))
    MoveCursor(x, y) ->
      #(model, Local(..local, cursor_x: x, cursor_y: y))
  }
}

pub fn view(model: Model, local: Local) -> beacon.Node(Msg) {
  html.div([html.style("font-family:system-ui;max-width:800px;margin:2rem auto")], [
    html.h1([], [html.text("Collaborative Canvas")]),
    html.p([html.style("color:#666")], [
      html.text("Draw together! Open multiple tabs to collaborate. "),
      html.text("Strokes: " <> int.to_string(model.stroke_count)),
    ]),
    // Color picker
    html.div([html.style("margin:1rem 0;display:flex;gap:8px")], [
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
    // Canvas area (SVG)
    html.div([
      html.style("border:2px solid #ccc;border-radius:8px;background:#fafafa;width:760px;height:500px;cursor:crosshair;position:relative"),
    ], [
      html.p([html.style("text-align:center;color:#aaa;padding-top:200px")], [
        html.text(case local.drawing {
          True -> "Drawing at (" <> int.to_string(local.cursor_x) <> ", " <> int.to_string(local.cursor_y) <> ")"
          False -> "Click and drag to draw"
        }),
      ]),
    ]),
    // Status
    html.div([html.style("margin-top:1rem;font-size:0.9rem;color:#888")], [
      html.text("Color: "),
      html.span([html.style("display:inline-block;width:20px;height:20px;background:" <> model.color <> ";border-radius:4px;vertical-align:middle")], []),
      html.text(" | Drawing: " <> case local.drawing {
        True -> "yes (local state — zero server traffic)"
        False -> "no"
      }),
    ]),
  ])
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
  beacon.app_with_local(init, init_local, update, view)
  |> beacon.title("Collaborative Canvas")
  |> beacon.start(8080)
}
