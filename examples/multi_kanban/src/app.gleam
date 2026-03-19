/// Multi-file Kanban — demonstrates external enum + record types from domain module.
/// Card and Column types live in domains/board.gleam.

import beacon
import beacon/html
import domains/board
import gleam/int
import gleam/list
import gleam/string

pub type Model {
  Model(
    cards: List(board.Card),
    next_id: Int,
    input: String,
    dragging_id: Int,
  )
}

pub type Msg {
  SetInput(String)
  AddCard
  StartDrag(String)
  DropOnColumn(String)
  DragOverColumn
  DeleteCard(Int)
}

pub fn init() -> Model {
  Model(
    cards: [
      board.Card(id: 1, title: "Design API", column: board.Todo),
      board.Card(id: 2, title: "Write tests", column: board.Doing),
      board.Card(id: 3, title: "Build UI", column: board.Todo),
    ],
    next_id: 4,
    input: "",
    dragging_id: -1,
  )
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    SetInput(text) -> Model(..model, input: text)
    AddCard -> {
      let title = string.trim(model.input)
      case string.is_empty(title) {
        True -> model
        False -> {
          let card =
            board.Card(id: model.next_id, title: title, column: board.Todo)
          Model(
            ..model,
            cards: list.append(model.cards, [card]),
            next_id: model.next_id + 1,
            input: "",
          )
        }
      }
    }
    StartDrag(id_str) ->
      case int.parse(id_str) {
        Ok(id) -> Model(..model, dragging_id: id)
        Error(_) -> model
      }
    DropOnColumn(col_str) ->
      case model.dragging_id >= 0 {
        False -> model
        True -> {
          let col = column_from_string(col_str)
          let new_cards =
            list.map(model.cards, fn(c) {
              case c.id == model.dragging_id {
                True -> board.Card(..c, column: col)
                False -> c
              }
            })
          Model(..model, cards: new_cards, dragging_id: -1)
        }
      }
    DragOverColumn -> model
    DeleteCard(id) ->
      Model(
        ..model,
        cards: list.filter(model.cards, fn(c) { c.id != id }),
        dragging_id: -1,
      )
  }
}

fn column_from_string(s: String) -> board.Column {
  case s {
    "doing" -> board.Doing
    "done" -> board.Done
    _ -> board.Todo
  }
}

fn column_to_string(c: board.Column) -> String {
  case c {
    board.Todo -> "todo"
    board.Doing -> "doing"
    board.Done -> "done"
  }
}

fn column_label(c: board.Column) -> String {
  case c {
    board.Todo -> "Todo"
    board.Doing -> "In Progress"
    board.Done -> "Done"
  }
}

fn column_color(c: board.Column) -> String {
  case c {
    board.Todo -> "#e3f2fd"
    board.Doing -> "#fff3e0"
    board.Done -> "#e8f5e9"
  }
}

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.div(
    [
      html.style(
        "font-family:system-ui;max-width:900px;margin:2rem auto;padding:0 1rem",
      ),
    ],
    [
      html.h1([], [html.text("Multi-File Kanban")]),
      html.p([html.style("color:#666;margin-bottom:1rem")], [
        html.text(
          "Drag cards between columns. Card/Column types from domains/board.gleam",
        ),
      ]),
      // Add card form
      html.div([html.style("display:flex;gap:8px;margin-bottom:1.5rem")], [
        html.input([
          html.type_("text"),
          html.placeholder("New card..."),
          html.value(model.input),
          beacon.on_input(SetInput),
          html.style(
            "flex:1;padding:10px;border:1px solid #ddd;border-radius:6px",
          ),
        ]),
        html.button(
          [
            beacon.on_click(AddCard),
            html.style(
              "padding:10px 20px;background:#4CAF50;color:white;border:none;border-radius:6px;cursor:pointer",
            ),
          ],
          [html.text("Add Card")],
        ),
      ]),
      // Columns
      html.div(
        [
          html.style(
            "display:grid;grid-template-columns:repeat(3,1fr);gap:1rem",
          ),
        ],
        [
          render_column(model, board.Todo),
          render_column(model, board.Doing),
          render_column(model, board.Done),
        ],
      ),
    ],
  )
}

fn render_column(model: Model, col: board.Column) -> beacon.Node(Msg) {
  let cards = list.filter(model.cards, fn(c) { c.column == col })
  let col_str = column_to_string(col)
  html.div(
    [
      html.style(
        "background:"
        <> column_color(col)
        <> ";border-radius:12px;padding:1rem;min-height:200px",
      ),
      beacon.on_dragover(DragOverColumn),
      beacon.on_drop(fn(_) { DropOnColumn(col_str) }),
    ],
    [
      html.h3(
        [
          html.style(
            "margin:0 0 1rem;color:#555;font-size:0.9rem;text-transform:uppercase",
          ),
        ],
        [
          html.text(
            column_label(col)
            <> " ("
            <> int.to_string(list.length(cards))
            <> ")",
          ),
        ],
      ),
      html.div(
        [html.style("display:flex;flex-direction:column;gap:8px")],
        list.map(cards, render_card),
      ),
    ],
  )
}

fn render_card(card: board.Card) -> beacon.Node(Msg) {
  html.div(
    [
      html.attribute("draggable", "true"),
      beacon.on_dragstart(StartDrag),
      html.attribute("data-drag-id", int.to_string(card.id)),
      html.style(
        "background:white;padding:12px;border-radius:8px;border:1px solid #e0e0e0;cursor:grab;display:flex;justify-content:space-between",
      ),
    ],
    [
      html.span([], [html.text(card.title)]),
      html.button(
        [
          beacon.on_click(DeleteCard(card.id)),
          html.style(
            "background:none;border:none;color:#bbb;cursor:pointer",
          ),
        ],
        [html.text("x")],
      ),
    ],
  )
}

pub fn main() {
  beacon.app(init, update, view)
  |> beacon.title("Multi-File Kanban")
  |> beacon.start(8080)
}
