/// Kanban Board — demonstrates:
/// - HTML5 Drag and Drop (on_dragstart, on_dragover, on_drop)
/// - Shared store for board state (multi-user concurrent edits)
/// - Dynamic PubSub subscriptions
/// - Cards moving between columns (Todo/Doing/Done)
/// - Pure update + on_update pattern (store calls separated from update logic)

import beacon
import beacon/effect
import beacon/html
import beacon/pubsub
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
    /// ID of card currently being dragged (-1 = none)
    dragging_id: Int,
  )
}

pub type Local {
  Local
}

pub type Msg {
  UpdateInput(String)
  AddCard
  StartDrag(String)
  DropOnColumn(String)
  DragOverColumn
  DeleteCard(Int)
  BoardUpdated
  /// Received from on_update after reading shared store — sets authoritative cards.
  SetCards(List(Card), Int)
}

fn column_from_string(s: String) -> Column {
  case s {
    "doing" -> Doing
    "done" -> Done
    _ -> Todo
  }
}

fn column_to_string(c: Column) -> String {
  case c {
    Todo -> "todo"
    Doing -> "doing"
    Done -> "done"
  }
}

fn column_label(c: Column) -> String {
  case c {
    Todo -> "Todo"
    Doing -> "In Progress"
    Done -> "Done"
  }
}

fn column_color(c: Column) -> String {
  case c {
    Todo -> "#e3f2fd"
    Doing -> "#fff3e0"
    Done -> "#e8f5e9"
  }
}

// --- Init ---

pub fn init() -> Model {
  Model(
    cards: [
      Card(id: 1, title: "Design API", column: Todo),
      Card(id: 2, title: "Write tests", column: Todo),
      Card(id: 3, title: "Build UI", column: Doing),
      Card(id: 4, title: "Deploy v0.1", column: Todo),
    ],
    next_id: 5,
    new_card_input: "",
    dragging_id: -1,
  )
}

pub fn init_local(_model: Model) -> Local {
  Local
}

// --- Update (pure — no stores, no side effects) ---

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    UpdateInput(text) -> #(Model(..model, new_card_input: text), local)

    AddCard -> {
      let title = string.trim(model.new_card_input)
      case string.is_empty(title) {
        True -> #(model, local)
        False -> {
          let card = Card(id: model.next_id, title: title, column: Todo)
          #(
            Model(
              ..model,
              cards: list.append(model.cards, [card]),
              next_id: model.next_id + 1,
              new_card_input: "",
            ),
            local,
          )
        }
      }
    }

    StartDrag(id_str) -> {
      case int.parse(id_str) {
        Ok(id) -> #(Model(..model, dragging_id: id), local)
        Error(_) -> #(model, local)
      }
    }

    DropOnColumn(col_str) -> {
      case model.dragging_id >= 0 {
        False -> #(model, local)
        True -> {
          let col = column_from_string(col_str)
          let new_cards =
            list.map(model.cards, fn(c) {
              case c.id == model.dragging_id {
                True -> Card(..c, column: col)
                False -> c
              }
            })
          #(Model(..model, cards: new_cards, dragging_id: -1), local)
        }
      }
    }

    DragOverColumn -> #(model, local)

    DeleteCard(id) -> {
      let new_cards = list.filter(model.cards, fn(c) { c.id != id })
      #(Model(..model, cards: new_cards, dragging_id: -1), local)
    }

    BoardUpdated -> #(model, local)

    SetCards(cards, next_id) ->
      #(Model(..model, cards: cards, next_id: next_id), local)
  }
}

// --- Side Effects (server only — store writes) ---

fn make_on_update(
  card_store: store.ListStore(Card),
) -> fn(#(Model, Local), Msg) -> effect.Effect(Msg) {
  fn(state: #(Model, Local), msg: Msg) -> effect.Effect(Msg) {
    let #(model, _local) = state
    case msg {
      AddCard | DropOnColumn(_) | DeleteCard(_) ->
        // Write full card list to shared store and notify other users
        effect.from(fn(_dispatch) {
          store.delete_all(card_store, "cards")
          store.append_many(card_store, "cards", model.cards)
          pubsub.broadcast("kanban:cards", Nil)
        })
      BoardUpdated ->
        // Read authoritative card list from shared store
        effect.from(fn(dispatch) {
          let cards = store.get_all(card_store, "cards")
          let next_id = case list.fold(cards, 0, fn(max, c) {
            case c.id > max {
              True -> c.id
              False -> max
            }
          }) {
            0 -> 5
            max -> max + 1
          }
          dispatch(SetCards(cards, next_id))
        })
      _ -> effect.none()
    }
  }
}

// --- View ---

pub fn view(model: Model, _local: Local) -> beacon.Node(Msg) {
  html.div(
    [
      html.style(
        "font-family:system-ui;max-width:900px;margin:2rem auto;padding:0 1rem",
      ),
    ],
    [
      html.h1([], [html.text("Kanban Board")]),
      html.p([html.style("color:#666;margin-bottom:1rem")], [
        html.text("Drag cards between columns"),
      ]),
      // Add card form
      html.div([html.style("display:flex;gap:8px;margin-bottom:1.5rem")], [
        html.input([
          html.type_("text"),
          html.placeholder("New card title..."),
          html.value(model.new_card_input),
          beacon.on_input(UpdateInput),
          html.style(
            "flex:1;padding:10px;border:1px solid #ddd;border-radius:6px;font-size:14px",
          ),
        ]),
        html.button(
          [
            beacon.on_click(AddCard),
            html.style(
              "padding:10px 20px;background:#4CAF50;color:white;border:none;border-radius:6px;cursor:pointer;font-size:14px;font-weight:500",
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
          render_column(model, Todo),
          render_column(model, Doing),
          render_column(model, Done),
        ],
      ),
    ],
  )
}

fn render_column(model: Model, col: Column) -> beacon.Node(Msg) {
  let cards = list.filter(model.cards, fn(c) { c.column == col })
  let col_str = column_to_string(col)
  html.div(
    [
      html.style(
        "background:"
        <> column_color(col)
        <> ";border-radius:12px;padding:1rem;min-height:250px;transition:outline 0.15s",
      ),
      // Drop target
      beacon.on_dragover(DragOverColumn),
      beacon.on_drop(fn(_id_str) { DropOnColumn(col_str) }),
      html.attribute("data-column", col_str),
    ],
    [
      html.h3(
        [html.style("margin:0 0 1rem 0;color:#555;font-size:0.9rem;text-transform:uppercase;letter-spacing:0.5px")],
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

fn render_card(card: Card) -> beacon.Node(Msg) {
  html.div(
    [
      html.attribute("draggable", "true"),
      html.attribute("data-drag-id", int.to_string(card.id)),
      beacon.on_dragstart(StartDrag),
      html.style(
        "background:white;padding:12px 16px;border-radius:8px;border:1px solid #e0e0e0;cursor:grab;display:flex;justify-content:space-between;align-items:center;box-shadow:0 1px 3px rgba(0,0,0,0.08);transition:box-shadow 0.15s,opacity 0.15s",
      ),
    ],
    [
      html.span([html.style("font-size:14px;color:#333")], [
        html.text(card.title),
      ]),
      html.button(
        [
          beacon.on_click(DeleteCard(card.id)),
          html.style(
            "background:none;border:none;color:#bbb;cursor:pointer;font-size:18px;padding:0 4px;line-height:1",
          ),
        ],
        [html.text("x")],
      ),
    ],
  )
}

// --- Start ---

pub fn main() {
  start()
}

pub fn start() {
  let card_store = store.new_list("kanban_cards")

  // Seed store with initial cards if empty
  case store.get_all(card_store, "cards") {
    [] -> {
      let initial_cards = [
        Card(id: 1, title: "Design API", column: Todo),
        Card(id: 2, title: "Write tests", column: Todo),
        Card(id: 3, title: "Build UI", column: Doing),
        Card(id: 4, title: "Deploy v0.1", column: Todo),
      ]
      store.append_many(card_store, "cards", initial_cards)
    }
    _ -> Nil
  }

  // Init reads from shared store — new sessions see existing cards
  let init_from_store = fn() {
    let cards = store.get_all(card_store, "cards")
    let next_id = case list.fold(cards, 0, fn(max, c) {
      case c.id > max {
        True -> c.id
        False -> max
      }
    }) {
      0 -> 5
      max_id -> max_id + 1
    }
    Model(cards: cards, next_id: next_id, new_card_input: "", dragging_id: -1)
  }

  beacon.app_with_local(init_from_store, init_local, update, view)
  |> beacon.title("Kanban Board")
  |> beacon.on_update(make_on_update(card_store))
  |> beacon.subscriptions(fn(_model) { ["kanban:cards"] })
  |> beacon.on_notify(fn(_topic) { BoardUpdated })
  |> beacon.start(8080)
}

