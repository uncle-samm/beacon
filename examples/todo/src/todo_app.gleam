/// Todo App — demonstrates:
/// - Form input with validation (reject empty)
/// - CRUD operations (add, toggle, delete, clear completed)
/// - LOCAL filter state (All/Active/Completed, zero server traffic)
/// - Derived values in view (items left counter, NOT stored in model)
/// - Multi-user via shared store
/// - Patch patterns: append (add), replace (toggle/delete)

import beacon
import beacon/effect
import beacon/html
import beacon/pubsub
import beacon/store
import gleam/int
import gleam/list
import gleam/string

// --- Types ---

pub type Todo {
  Todo(id: Int, text: String, completed: Bool)
}

pub type Model {
  Model(
    todos: List(Todo),
    input_text: String,
    next_id: Int,
  )
}

pub type Local {
  Local(
    /// "all", "active", or "completed"
    filter: String,
  )
}

pub type Msg {
  AddTodo
  ToggleTodo(String)
  DeleteTodo(String)
  SetInput(String)
  SetFilter(String)
  ClearCompleted
  TodosUpdated
  SetTodos(List(Todo))
}

// --- Init ---

pub fn init() -> Model {
  Model(todos: [], input_text: "", next_id: 1)
}

pub fn init_local(_model: Model) -> Local {
  Local(filter: "all")
}

// --- Update (pure — compiles to JS) ---

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    SetInput(text) -> #(Model(..model, input_text: text), local)

    SetFilter(f) -> #(model, Local(filter: f))

    AddTodo -> {
      let title = string.trim(model.input_text)
      case string.is_empty(title) {
        True -> #(model, local)
        False -> {
          let new_todo = Todo(id: model.next_id, text: title, completed: False)
          #(
            Model(
              ..model,
              todos: list.append(model.todos, [new_todo]),
              next_id: model.next_id + 1,
              input_text: "",
            ),
            local,
          )
        }
      }
    }

    ToggleTodo(id_str) -> {
      case int.parse(id_str) {
        Ok(id) -> {
          let new_todos =
            list.map(model.todos, fn(t) {
              case t.id == id {
                True -> Todo(..t, completed: !t.completed)
                False -> t
              }
            })
          #(Model(..model, todos: new_todos), local)
        }
        Error(_) -> #(model, local)
      }
    }

    DeleteTodo(id_str) -> {
      case int.parse(id_str) {
        Ok(id) -> {
          let new_todos = list.filter(model.todos, fn(t) { t.id != id })
          #(Model(..model, todos: new_todos), local)
        }
        Error(_) -> #(model, local)
      }
    }

    ClearCompleted -> {
      let new_todos = list.filter(model.todos, fn(t) { !t.completed })
      #(Model(..model, todos: new_todos), local)
    }

    TodosUpdated -> #(model, local)

    SetTodos(todos) -> {
      let next_id = case list.fold(todos, 0, fn(max, t) {
        case t.id > max {
          True -> t.id
          False -> max
        }
      }) {
        0 -> model.next_id
        max -> max + 1
      }
      #(Model(..model, todos: todos, next_id: next_id), local)
    }
  }
}

// --- Side Effects ---

fn make_on_update(
  todo_store: store.ListStore(Todo),
) -> fn(#(Model, Local), Msg) -> effect.Effect(Msg) {
  fn(state: #(Model, Local), msg: Msg) -> effect.Effect(Msg) {
    let #(model, _local) = state
    case msg {
      AddTodo | ToggleTodo(_) | DeleteTodo(_) | ClearCompleted -> {
        effect.from(fn(_dispatch) {
          let store_count = list.length(store.get_all(todo_store, "todos"))
          let model_count = list.length(model.todos)
          case model_count != store_count || model_count == 0 {
            True -> {
              store.delete_all(todo_store, "todos")
              store.append_many(todo_store, "todos", model.todos)
              pubsub.broadcast("todo:updated", Nil)
            }
            False -> {
              store.delete_all(todo_store, "todos")
              store.append_many(todo_store, "todos", model.todos)
              pubsub.broadcast("todo:updated", Nil)
            }
          }
        })
      }
      TodosUpdated -> {
        let store_todos = store.get_all(todo_store, "todos")
        case list.length(store_todos) != list.length(model.todos) {
          True ->
            effect.from(fn(dispatch) { dispatch(SetTodos(store_todos)) })
          False -> effect.none()
        }
      }
      _ -> effect.none()
    }
  }
}

// --- View ---

pub fn view(model: Model, local: Local) -> beacon.Node(Msg) {
  let filtered_todos = case local.filter {
    "active" -> list.filter(model.todos, fn(t) { !t.completed })
    "completed" -> list.filter(model.todos, fn(t) { t.completed })
    _ -> model.todos
  }
  let active_count =
    list.length(list.filter(model.todos, fn(t) { !t.completed }))
  let has_completed = list.any(model.todos, fn(t) { t.completed })

  html.div(
    [
      html.style(
        "font-family:system-ui;max-width:500px;margin:2rem auto;padding:0 1rem",
      ),
    ],
    [
      html.h1([], [html.text("Todo App")]),
      // Input form
      html.div([html.style("display:flex;gap:8px;margin-bottom:1rem")], [
        html.input([
          html.type_("text"),
          html.placeholder("What needs to be done?"),
          html.value(model.input_text),
          beacon.on_input(SetInput),
          html.style(
            "flex:1;padding:10px;border:1px solid #ddd;border-radius:6px;font-size:14px",
          ),
        ]),
        html.button(
          [
            beacon.on_click(AddTodo),
            html.style(
              "padding:10px 20px;background:#4CAF50;color:white;border:none;border-radius:6px;cursor:pointer",
            ),
          ],
          [html.text("Add")],
        ),
      ]),
      // Filter buttons
      html.div(
        [html.style("display:flex;gap:8px;margin-bottom:1rem")],
        [
          filter_button("all", "All", local.filter),
          filter_button("active", "Active", local.filter),
          filter_button("completed", "Completed", local.filter),
        ],
      ),
      // Todo list
      html.div(
        [],
        list.map(filtered_todos, fn(t) { render_todo(t) }),
      ),
      // Footer
      html.div(
        [html.style("display:flex;justify-content:space-between;margin-top:1rem;padding-top:0.5rem;border-top:1px solid #eee;color:#666;font-size:14px")],
        [
          html.span([], [
            html.text(
              int.to_string(active_count) <> " item" <> case active_count {
                1 -> ""
                _ -> "s"
              } <> " left",
            ),
          ]),
          case has_completed {
            True ->
              html.button(
                [
                  beacon.on_click(ClearCompleted),
                  html.style(
                    "background:none;border:1px solid #ddd;border-radius:4px;padding:4px 12px;cursor:pointer;color:#666",
                  ),
                ],
                [html.text("Clear completed")],
              )
            False -> html.text("")
          },
        ],
      ),
    ],
  )
}

fn render_todo(item: Todo) -> beacon.Node(Msg) {
  let style = case item.completed {
    True -> "text-decoration:line-through;color:#999"
    False -> "color:#333"
  }
  html.div(
    [html.style("display:flex;align-items:center;gap:8px;padding:8px 0;border-bottom:1px solid #f0f0f0")],
    [
      html.button(
        [
          beacon.on_click(ToggleTodo(int.to_string(item.id))),
          html.style("width:24px;height:24px;border:2px solid #ccc;border-radius:50%;cursor:pointer;background:" <> case item.completed {
            True -> "#4CAF50"
            False -> "white"
          }),
        ],
        [],
      ),
      html.span([html.style(style <> ";flex:1;font-size:14px")], [
        html.text(item.text),
      ]),
      html.button(
        [
          beacon.on_click(DeleteTodo(int.to_string(item.id))),
          html.style("background:none;border:none;color:#e57373;cursor:pointer;font-size:18px"),
        ],
        [html.text("x")],
      ),
    ],
  )
}

fn filter_button(
  value: String,
  label: String,
  current: String,
) -> beacon.Node(Msg) {
  let bg = case value == current {
    True -> "background:#e3f2fd;border-color:#2196F3;color:#2196F3"
    False -> "background:white;border-color:#ddd;color:#666"
  }
  html.button(
    [
      beacon.on_click(SetFilter(value)),
      html.style(
        "padding:6px 16px;border:1px solid;border-radius:4px;cursor:pointer;" <> bg,
      ),
    ],
    [html.text(label)],
  )
}

// --- Start ---

pub fn main() {
  start()
}

pub fn start() {
  let todo_store = store.new_list("todo_items")

  let init_from_store = fn() {
    let todos = store.get_all(todo_store, "todos")
    let max_id =
      list.fold(todos, 0, fn(acc, t: Todo) {
        case t.id > acc {
          True -> t.id
          False -> acc
        }
      })
    let next_id = case max_id {
      0 -> 1
      n -> n + 1
    }
    Model(todos: todos, input_text: "", next_id: next_id)
  }

  beacon.app_with_local(init_from_store, init_local, update, view)
  |> beacon.title("Todo App")
  |> beacon.on_update(make_on_update(todo_store))
  |> beacon.subscriptions(fn(_model) { ["todo:updated"] })
  |> beacon.on_notify(fn(_topic) { TodosUpdated })
  |> beacon.start(8080)
}
