/// Spreadsheet — demonstrates:
/// - Large model (200 cells), single-cell edits
/// - Click-to-edit UI with LOCAL editing state
/// - Grid rendering with column/row headers
/// - Multi-user: edit cell in tab A → updates in tab B
/// - Patch patterns: replace on full cell list per edit

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

pub type Cell {
  Cell(row: Int, col: Int, value: String)
}

pub type Model {
  Model(cells: List(Cell))
}

pub type Local {
  Local(
    selected_row: Int,
    selected_col: Int,
    editing: Bool,
    edit_buffer: String,
  )
}

pub type Msg {
  SelectCell(String)
  StartEdit
  UpdateBuffer(String)
  ConfirmEdit
  CancelEdit
  CellsUpdated
  SetCells(List(Cell))
}

const num_rows = 10

const num_cols = 5

fn col_name(col: Int) -> String {
  case col {
    0 -> "A"
    1 -> "B"
    2 -> "C"
    3 -> "D"
    4 -> "E"
    _ -> "?"
  }
}

fn cell_key(row: Int, col: Int) -> String {
  col_name(col) <> int.to_string(row + 1)
}

fn default_cells() -> List(Cell) {
  list.flat_map(list.repeat(Nil, num_rows), fn(_) { [] })
  |> fn(_) {
    build_cells(0, 0, [])
  }
}

fn build_cells(row: Int, col: Int, acc: List(Cell)) -> List(Cell) {
  case row >= num_rows {
    True -> list.reverse(acc)
    False ->
      case col >= num_cols {
        True -> build_cells(row + 1, 0, acc)
        False ->
          build_cells(row, col + 1, [Cell(row: row, col: col, value: ""), ..acc])
      }
  }
}

fn parse_cell_key(key: String) -> #(Int, Int) {
  let col = case string.slice(key, 0, 1) {
    "A" -> 0
    "B" -> 1
    "C" -> 2
    "D" -> 3
    "E" -> 4
    _ -> 0
  }
  let row = case int.parse(string.drop_start(key, 1)) {
    Ok(n) -> n - 1
    Error(_) -> 0
  }
  #(row, col)
}

fn get_cell_value(cells: List(Cell), row: Int, col: Int) -> String {
  case list.find(cells, fn(c) { c.row == row && c.col == col }) {
    Ok(cell) -> cell.value
    Error(_) -> ""
  }
}

// --- Init ---

pub fn init() -> Model {
  Model(cells: default_cells())
}

pub fn init_local(_model: Model) -> Local {
  Local(selected_row: -1, selected_col: -1, editing: False, edit_buffer: "")
}

// --- Update ---

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    SelectCell(key) -> {
      let #(row, col) = parse_cell_key(key)
      let value = get_cell_value(model.cells, row, col)
      #(model, Local(
        selected_row: row,
        selected_col: col,
        editing: False,
        edit_buffer: value,
      ))
    }

    StartEdit -> #(model, Local(..local, editing: True))

    UpdateBuffer(text) -> #(model, Local(..local, edit_buffer: text))

    ConfirmEdit -> {
      case local.selected_row >= 0 && local.selected_col >= 0 {
        True -> {
          let new_cells =
            list.map(model.cells, fn(c) {
              case c.row == local.selected_row && c.col == local.selected_col {
                True -> Cell(..c, value: local.edit_buffer)
                False -> c
              }
            })
          #(
            Model(cells: new_cells),
            Local(..local, editing: False),
          )
        }
        False -> #(model, Local(..local, editing: False))
      }
    }

    CancelEdit -> {
      let value = get_cell_value(model.cells, local.selected_row, local.selected_col)
      #(model, Local(..local, editing: False, edit_buffer: value))
    }

    CellsUpdated -> #(model, local)

    SetCells(cells) -> #(Model(cells: cells), local)
  }
}

// --- Side Effects ---

fn make_on_update(
  cell_store: store.ListStore(Cell),
) -> fn(#(Model, Local), Msg) -> effect.Effect(Msg) {
  fn(state: #(Model, Local), msg: Msg) -> effect.Effect(Msg) {
    let #(model, _local) = state
    case msg {
      ConfirmEdit ->
        effect.from(fn(_dispatch) {
          store.delete_all(cell_store, "cells")
          store.append_many(cell_store, "cells", model.cells)
          pubsub.broadcast("spreadsheet:cells", Nil)
        })
      CellsUpdated -> {
        let store_cells = store.get_all(cell_store, "cells")
        case list.length(store_cells) > 0 {
          True ->
            effect.from(fn(dispatch) { dispatch(SetCells(store_cells)) })
          False -> effect.none()
        }
      }
      _ -> effect.none()
    }
  }
}

// --- View ---

pub fn view(model: Model, local: Local) -> beacon.Node(Msg) {
  html.div(
    [html.style("font-family:system-ui;max-width:900px;margin:2rem auto;padding:0 1rem")],
    [
      html.h1([], [html.text("Spreadsheet")]),
      html.p([html.style("color:#666;margin-bottom:1rem")], [
        html.text("Click a cell to select, click again to edit. Press Enter to confirm."),
      ]),
      // Grid
      html.div(
        [html.style("border:1px solid #ccc;border-radius:4px;overflow:auto")],
        [
          // Header row
          element.el(
            "table",
            [
              html.style("border-collapse:collapse;width:100%"),
              html.attribute("data-grid", "true"),
            ],
            [
              element.el("thead", [], [
                element.el("tr", [], [
                  element.el(
                    "th",
                    [html.style("width:40px;padding:8px;background:#f5f5f5;border:1px solid #ddd")],
                    [],
                  ),
                  ..list.map(list.repeat(Nil, num_cols), fn(_) { Nil })
                  |> list.index_map(fn(_x, i) {
                    element.el(
                      "th",
                      [html.style("padding:8px;background:#f5f5f5;border:1px solid #ddd;min-width:80px;font-weight:600;color:#555")],
                      [element.text(col_name(i))],
                    )
                  })
                ]),
              ]),
              element.el("tbody", [], render_rows(model, local)),
            ],
          ),
        ],
      ),
      // Status
      html.div(
        [html.style("margin-top:0.5rem;font-size:0.85rem;color:#999")],
        [
          html.text(case local.selected_row >= 0 {
            True ->
              "Selected: "
              <> cell_key(local.selected_row, local.selected_col)
              <> case local.editing {
                True -> " (editing)"
                False -> ""
              }
            False -> "Click a cell to select"
          }),
        ],
      ),
    ],
  )
}

fn render_rows(model: Model, local: Local) -> List(beacon.Node(Msg)) {
  list.repeat(Nil, num_rows)
  |> list.index_map(fn(_x, row) { render_row(model, local, row) })
}

fn render_row(model: Model, local: Local, row: Int) -> beacon.Node(Msg) {
  element.el("tr", [], [
    element.el(
      "td",
      [html.style("padding:4px 8px;background:#f5f5f5;border:1px solid #ddd;text-align:center;font-weight:600;color:#555;font-size:13px")],
      [element.text(int.to_string(row + 1))],
    ),
    ..list.repeat(Nil, num_cols)
    |> list.index_map(fn(_x, col) { render_cell(model, local, row, col) })
  ])
}

fn render_cell(
  model: Model,
  local: Local,
  row: Int,
  col: Int,
) -> beacon.Node(Msg) {
  let is_selected = row == local.selected_row && col == local.selected_col
  let is_editing = is_selected && local.editing
  let value = get_cell_value(model.cells, row, col)
  let key = cell_key(row, col)

  let border = case is_selected {
    True -> "border:2px solid #2196F3"
    False -> "border:1px solid #ddd"
  }

  case is_editing {
    True ->
      element.el(
        "td",
        [html.style(border <> ";padding:0")],
        [
          html.input([
            html.type_("text"),
            html.value(local.edit_buffer),
            beacon.on_input(UpdateBuffer),
            beacon.on_keydown(fn(k) {
              case k {
                "Enter" -> ConfirmEdit
                "Escape" -> CancelEdit
                _ -> UpdateBuffer(local.edit_buffer)
              }
            }),
            html.style("width:100%;padding:4px 8px;border:none;outline:none;font-size:13px;box-sizing:border-box"),
          ]),
        ],
      )
    False ->
      element.el(
        "td",
        [
          html.style(border <> ";padding:4px 8px;cursor:pointer;min-height:24px;font-size:13px"),
          beacon.on_click(case is_selected {
            True -> StartEdit
            False -> SelectCell(key)
          }),
        ],
        [element.text(value)],
      )
  }
}

// --- Start ---

pub fn main() {
  start()
}

pub fn start() {
  let cell_store = store.new_list("spreadsheet_cells")

  let init_from_store = fn() {
    let cells = case store.get_all(cell_store, "cells") {
      [] -> default_cells()
      stored -> stored
    }
    Model(cells: cells)
  }

  beacon.app_with_local(init_from_store, init_local, update, view)
  |> beacon.title("Spreadsheet")
  |> beacon.on_update(make_on_update(cell_store))
  |> beacon.subscriptions(fn(_model) { ["spreadsheet:cells"] })
  |> beacon.on_notify(fn(_topic) { CellsUpdated })
  |> beacon.start(8080)
}
