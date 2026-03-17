/// Kanban Board — demonstrates:
/// - Drag and drop (on_click to select, on_click to place)
/// - Shared store for board state (multi-user concurrent edits)
/// - Dynamic PubSub subscriptions
/// - Cards moving between columns (Todo/Doing/Done)

import beacon
import beacon/html
import beacon/store
import gleam/int
import gleam/list
import gleam/string

// --- Types ---

pub type Column {
  Todo
  Doing
  Done
}

pub type Card {
  Card(id: Int, title: String, column: Column)
}

pub type Model {
  Model(
    cards: List(Card),
    next_id: Int,
    new_card_input: String,
    /// Which card is being moved (None = nothing selected)
    moving_card_id: Int,
  )
}

pub type Msg {
  UpdateInput(String)
  AddCard
  PickUpCard(Int)
  MoveToColumn(Column)
  DeleteCard(Int)
  BoardUpdated
}

// --- Init ---

pub fn init() -> Model {
  Model(
    cards: [
      Card(id: 1, title: "Design API", column: Todo),
      Card(id: 2, title: "Write tests", column: Todo),
      Card(id: 3, title: "Build UI", column: Doing),
    ],
    next_id: 4,
    new_card_input: "",
    moving_card_id: -1,
  )
}

// --- Update ---

pub fn make_update(
  board_store: store.Store(String),
) -> fn(Model, Msg) -> Model {
  fn(model: Model, msg: Msg) -> Model {
    case msg {
      UpdateInput(text) -> Model(..model, new_card_input: text)

      AddCard -> {
        let title = string.trim(model.new_card_input)
        case string.is_empty(title) {
          True -> model
          False -> {
            let card = Card(id: model.next_id, title: title, column: Todo)
            let new_model =
              Model(
                ..model,
                cards: list.append(model.cards, [card]),
                next_id: model.next_id + 1,
                new_card_input: "",
              )
            store.put(board_store, "version", int.to_string(new_model.next_id))
            new_model
          }
        }
      }

      PickUpCard(id) -> {
        case model.moving_card_id == id {
          // Toggle off if same card clicked
          True -> Model(..model, moving_card_id: -1)
          False -> Model(..model, moving_card_id: id)
        }
      }

      MoveToColumn(col) -> {
        case model.moving_card_id >= 0 {
          False -> model
          True -> {
            let new_cards =
              list.map(model.cards, fn(c) {
                case c.id == model.moving_card_id {
                  True -> Card(..c, column: col)
                  False -> c
                }
              })
            let new_model =
              Model(..model, cards: new_cards, moving_card_id: -1)
            store.put(board_store, "version", int.to_string(unique_int()))
            new_model
          }
        }
      }

      DeleteCard(id) -> {
        let new_cards = list.filter(model.cards, fn(c) { c.id != id })
        let new_model = Model(..model, cards: new_cards, moving_card_id: -1)
        store.put(board_store, "version", int.to_string(unique_int()))
        new_model
      }

      BoardUpdated -> model
    }
  }
}

// --- View ---

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.div(
    [
      html.style(
        "font-family:system-ui;max-width:900px;margin:2rem auto;padding:0 1rem",
      ),
    ],
    [
      html.h1([], [html.text("Kanban Board")]),
      // Add card form
      html.div([html.style("display:flex;gap:8px;margin-bottom:1.5rem")], [
        html.input([
          html.type_("text"),
          html.placeholder("New card title..."),
          html.value(model.new_card_input),
          beacon.on_input(UpdateInput),
          html.style("flex:1;padding:8px;border:1px solid #ccc;border-radius:4px"),
        ]),
        html.button(
          [
            beacon.on_click(AddCard),
            html.style(
              "padding:8px 16px;background:#4CAF50;color:white;border:none;border-radius:4px;cursor:pointer",
            ),
          ],
          [html.text("Add Card")],
        ),
      ]),
      // Moving indicator
      case model.moving_card_id >= 0 {
        True -> {
          let card_title =
            list.find(model.cards, fn(c) { c.id == model.moving_card_id })
          case card_title {
            Ok(c) ->
              html.p(
                [
                  html.style(
                    "background:#fff3cd;padding:8px;border-radius:4px;margin-bottom:1rem",
                  ),
                ],
                [
                  html.text(
                    "Moving: \"" <> c.title <> "\" — click a column to place it",
                  ),
                ],
              )
            Error(_) -> html.text("")
          }
        }
        False -> html.text("")
      },
      // Columns
      html.div(
        [
          html.style(
            "display:grid;grid-template-columns:repeat(3,1fr);gap:1rem",
          ),
        ],
        [
          render_column(model, Todo, "Todo", "#e3f2fd"),
          render_column(model, Doing, "In Progress", "#fff3e0"),
          render_column(model, Done, "Done", "#e8f5e9"),
        ],
      ),
    ],
  )
}

fn render_column(
  model: Model,
  col: Column,
  title: String,
  bg: String,
) -> beacon.Node(Msg) {
  let cards = list.filter(model.cards, fn(c) { c.column == col })
  html.div(
    [
      html.style(
        "background:" <> bg <> ";border-radius:8px;padding:1rem;min-height:200px",
      ),
      // Click column to move card here
      beacon.on_click(MoveToColumn(col)),
    ],
    [
      html.h3(
        [html.style("margin:0 0 1rem 0;color:#333")],
        [
          html.text(
            title <> " (" <> int.to_string(list.length(cards)) <> ")",
          ),
        ],
      ),
      html.div(
        [html.style("display:flex;flex-direction:column;gap:8px")],
        list.map(cards, fn(c) { render_card(c, model.moving_card_id) }),
      ),
    ],
  )
}

fn render_card(card: Card, moving_id: Int) -> beacon.Node(Msg) {
  let is_moving = card.id == moving_id
  let border = case is_moving {
    True -> "border:2px solid #2196F3"
    False -> "border:1px solid #ddd"
  }
  html.div(
    [
      html.style(
        "background:white;padding:12px;border-radius:6px;"
        <> border
        <> ";display:flex;justify-content:space-between;align-items:center;cursor:pointer",
      ),
      beacon.on_click(PickUpCard(card.id)),
    ],
    [
      html.span([], [html.text(card.title)]),
      html.button(
        [
          beacon.on_click(DeleteCard(card.id)),
          html.style(
            "background:none;border:none;color:#999;cursor:pointer;font-size:16px",
          ),
        ],
        [html.text("x")],
      ),
    ],
  )
}

// --- Start ---

pub fn start() {
  let board_store = store.new("kanban_board")

  beacon.app(init, make_update(board_store), view)
  |> beacon.title("Kanban Board")
  |> beacon.subscriptions(fn(_model) { ["store:kanban_board"] })
  |> beacon.on_notify(fn(_topic) { BoardUpdated })
  |> beacon.start(8080)
}

@external(erlang, "erlang", "unique_integer")
fn unique_int() -> Int
