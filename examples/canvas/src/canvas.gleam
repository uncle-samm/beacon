/// Collaborative Canvas — demonstrates:
/// - Pure update + on_update pattern (LOCAL events for instant drawing)
/// - Shared store for strokes (multi-user concurrent drawing)
/// - Dynamic PubSub subscriptions
/// - SVG rendering with real-time updates
/// - Mouse events (mousedown, mousemove, mouseup)
///
/// LOCAL events (zero server traffic):
///   StartDrawing, MoveCursor, StopDrawing
///
/// MODEL events (synced to server):
///   SetColor, ClearCanvas, StrokesUpdated

import beacon
import beacon/effect
import beacon/element
import beacon/html
import beacon/pubsub
import beacon/store
import gleam/int
import gleam/list
import gleam/string

// --- Types ---

pub type Stroke {
  Stroke(x1: Int, y1: Int, x2: Int, y2: Int, color: String)
}

pub type Model {
  Model(
    strokes: List(Stroke),
    color: String,
  )
}

pub type Local {
  Local(
    drawing: Bool,
    cursor_x: Int,
    cursor_y: Int,
    pending_strokes: List(Stroke),
  )
}

pub type Msg {
  StartDrawing(String)
  MoveCursor(String)
  StopDrawing
  SetColor(String)
  ClearCanvas
  StrokesUpdated
  /// Received from on_update after reading shared store — sets authoritative strokes.
  SetStrokes(List(Stroke))
}

// --- Init ---

pub fn init() -> Model {
  Model(strokes: [], color: "#000000")
}

pub fn init_local(_model: Model) -> Local {
  Local(drawing: False, cursor_x: 0, cursor_y: 0, pending_strokes: [])
}

// --- Update (pure — no stores, compiles to JS) ---

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    StartDrawing(coords) -> {
      let #(x, y) = parse_coords(coords)
      #(model, Local(..local, drawing: True, cursor_x: x, cursor_y: y))
    }

    MoveCursor(coords) -> {
      let #(x, y) = parse_coords(coords)
      case local.drawing {
        True -> {
          let stroke =
            Stroke(
              x1: local.cursor_x,
              y1: local.cursor_y,
              x2: x,
              y2: y,
              color: model.color,
            )
          #(
            model,
            Local(
              ..local,
              cursor_x: x,
              cursor_y: y,
              pending_strokes: [stroke, ..local.pending_strokes],
            ),
          )
        }
        False -> #(model, Local(..local, cursor_x: x, cursor_y: y))
      }
    }

    StopDrawing -> {
      // Commit pending strokes to model
      let committed =
        list.append(model.strokes, list.reverse(local.pending_strokes))
      #(
        Model(..model, strokes: committed),
        Local(..local, drawing: False, pending_strokes: []),
      )
    }

    SetColor(c) -> #(Model(..model, color: c), local)

    ClearCanvas -> #(Model(..model, strokes: []), local)

    StrokesUpdated -> #(model, local)

    SetStrokes(strokes) -> {
      // Only update if strokes actually changed (avoid feedback loops)
      case list.length(strokes) == list.length(model.strokes) {
        True -> #(model, local)
        False -> #(Model(..model, strokes: strokes), local)
      }
    }
  }
}

// --- Side Effects (server only — store writes) ---

fn make_on_update(
  stroke_store: store.ListStore(Stroke),
) -> fn(#(Model, Local), Msg) -> effect.Effect(Msg) {
  fn(state: #(Model, Local), msg: Msg) -> effect.Effect(Msg) {
    let #(_model, _local) = state
    case msg {
      StopDrawing -> {
        let #(model, _local) = state
        // Only append NEW strokes to the store (not the full list).
        // Compare store length vs model length to find the delta.
        // This ensures the diff detects "append" instead of "replace".
        effect.from(fn(_dispatch) {
          let store_count = list.length(store.get_all(stroke_store, "canvas"))
          let model_count = list.length(model.strokes)
          case model_count > store_count {
            True -> {
              // New strokes = tail of model.strokes beyond what's in the store
              let new_strokes = list.drop(model.strokes, store_count)
              store.append_many(stroke_store, "canvas", new_strokes)
              pubsub.broadcast("store:canvas_strokes", Nil)
            }
            False -> Nil
          }
        })
      }
      ClearCanvas ->
        effect.from(fn(_dispatch) {
          store.delete_all_notify(stroke_store, "canvas", "canvas:")
        })
      StrokesUpdated -> {
        // Reload strokes from store (another user drew something).
        // Only dispatch if store has MORE strokes than our model (avoids feedback).
        let #(model, _local) = state
        let store_strokes = store.get_all(stroke_store, "canvas")
        case list.length(store_strokes) > list.length(model.strokes) {
          True ->
            effect.from(fn(dispatch) {
              dispatch(SetStrokes(store_strokes))
            })
          False -> effect.none()
        }
      }
      _ -> effect.none()
    }
  }
}

// --- View ---

pub fn view(model: Model, local: Local) -> beacon.Node(Msg) {
  let all_strokes = list.append(model.strokes, local.pending_strokes)
  html.div(
    [
      html.style(
        "font-family:system-ui;max-width:800px;margin:2rem auto;padding:0 1rem",
      ),
    ],
    [
      html.h1([], [html.text("Collaborative Canvas")]),
      html.p([html.style("color:#666;margin-bottom:1rem")], [
        html.text(
          "Draw together! Open multiple tabs. Strokes: "
          <> int.to_string(list.length(all_strokes)),
        ),
      ]),
      // Color picker
      html.div(
        [html.style("margin-bottom:1rem;display:flex;gap:8px;align-items:center")],
        [
          color_button("#000000", model.color),
          color_button("#ff0000", model.color),
          color_button("#0000ff", model.color),
          color_button("#00aa00", model.color),
          color_button("#ff8800", model.color),
          color_button("#8800ff", model.color),
          html.button(
            [
              beacon.on_click(ClearCanvas),
              html.style(
                "margin-left:auto;padding:6px 16px;background:#f44336;color:white;border:none;border-radius:4px;cursor:pointer",
              ),
            ],
            [html.text("Clear")],
          ),
        ],
      ),
      // SVG Canvas
      element.el(
        "svg",
        [
          html.attribute("width", "760"),
          html.attribute("height", "500"),
          html.attribute("viewBox", "0 0 760 500"),
          html.style(
            "border:2px solid #ddd;border-radius:8px;background:#fafafa;cursor:crosshair;display:block",
          ),
          beacon.on_mousedown(StartDrawing),
          beacon.on_mousemove(MoveCursor),
          beacon.on_mouseup(StopDrawing),
        ],
        list.map(all_strokes, render_stroke),
      ),
      // Status
      html.div(
        [html.style("margin-top:0.5rem;font-size:0.85rem;color:#999")],
        [
          html.text("Color: "),
          element.el(
            "span",
            [
              html.style(
                "display:inline-block;width:16px;height:16px;background:"
                <> model.color
                <> ";border-radius:3px;vertical-align:middle",
              ),
            ],
            [],
          ),
          html.text(
            " | "
            <> case local.drawing {
              True ->
                "Drawing at ("
                <> int.to_string(local.cursor_x)
                <> ","
                <> int.to_string(local.cursor_y)
                <> ")"
              False -> "Click and drag to draw"
            },
          ),
        ],
      ),
    ],
  )
}

fn render_stroke(stroke: Stroke) -> beacon.Node(Msg) {
  element.el(
    "line",
    [
      html.attribute("x1", int.to_string(stroke.x1)),
      html.attribute("y1", int.to_string(stroke.y1)),
      html.attribute("x2", int.to_string(stroke.x2)),
      html.attribute("y2", int.to_string(stroke.y2)),
      html.attribute("stroke", stroke.color),
      html.attribute("stroke-width", "3"),
      html.attribute("stroke-linecap", "round"),
    ],
    [],
  )
}

fn color_button(color: String, selected: String) -> beacon.Node(Msg) {
  let border = case color == selected {
    True -> "3px solid #333"
    False -> "1px solid #ccc"
  }
  html.button(
    [
      beacon.on_click(SetColor(color)),
      html.style(
        "width:32px;height:32px;background:"
        <> color
        <> ";border:"
        <> border
        <> ";border-radius:4px;cursor:pointer",
      ),
    ],
    [],
  )
}

fn parse_coords(coords: String) -> #(Int, Int) {
  case string.split(coords, ",") {
    [x_str, y_str] -> {
      let x = case int.parse(x_str) {
        Ok(n) -> n
        Error(_) -> 0
      }
      let y = case int.parse(y_str) {
        Ok(n) -> n
        Error(_) -> 0
      }
      #(x, y)
    }
    _ -> #(0, 0)
  }
}

// --- Start ---

pub fn start() {
  let stroke_store = store.new_list("canvas_strokes")

  // Init reads from shared store — new sessions see existing strokes
  let init_from_store = fn() {
    let strokes = store.get_all(stroke_store, "canvas")
    Model(strokes: strokes, color: "#000000")
  }

  beacon.app_with_local(init_from_store, init_local, update, view)
  |> beacon.title("Collaborative Canvas")
  |> beacon.on_update(make_on_update(stroke_store))
  |> beacon.subscriptions(fn(_model) { ["store:canvas_strokes"] })
  |> beacon.on_notify(fn(_topic) { StrokesUpdated })
  |> beacon.start(8080)
}

pub fn main() {
  start()
}
