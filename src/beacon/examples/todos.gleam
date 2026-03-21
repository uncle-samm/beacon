/// Todo app example — a full multi-feature Beacon application.
/// Demonstrates: forms, validation, lists, filtering, memo, SSR, hydration.

import beacon/effect
import beacon/element
import beacon/error
import beacon/form
import beacon/log
import beacon/runtime
import beacon/ssr
import beacon/transport
import gleam/int
import gleam/list
import gleam/option
import gleam/string

/// A single todo item.
pub type TodoItem {
  TodoItem(id: Int, text: String, completed: Bool)
}

/// The app model.
pub type Model {
  Model(
    todos: List(TodoItem),
    next_id: Int,
    input_form: form.Form,
    filter: Filter,
  )
}

/// Visibility filter.
pub type Filter {
  All
  Active
  Completed
}

/// App messages.
pub type Msg {
  AddTodo
  ToggleTodo(id: Int)
  DeleteTodo(id: Int)
  ClearCompleted
  SetFilter(Filter)
  UpdateInput(value: String)
}

/// Initialize the model.
pub fn init() -> #(Model, effect.Effect(Msg)) {
  let input_form =
    form.new("todo-secret-key-change-in-production!!")
    |> form.add_field("new_todo", "")
  #(
    Model(
      todos: [],
      next_id: 1,
      input_form: input_form,
      filter: All,
    ),
    effect.none(),
  )
}

/// Update the model.
pub fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    AddTodo -> {
      let text = form.get_value(model.input_form, "new_todo")
      let trimmed = string.trim(text)
      case string.is_empty(trimmed) {
        True -> {
          let new_form =
            model.input_form
            |> form.clear_errors
            |> form.validate_required("new_todo")
          #(Model(..model, input_form: new_form), effect.none())
        }
        False -> {
          let new_todo =
            TodoItem(id: model.next_id, text: trimmed, completed: False)
          let new_form =
            model.input_form
            |> form.clear_errors
            |> form.set_value("new_todo", "")
          log.info("todo", "Added: " <> trimmed)
          #(
            Model(
              ..model,
              todos: list.append(model.todos, [new_todo]),
              next_id: model.next_id + 1,
              input_form: new_form,
            ),
            effect.none(),
          )
        }
      }
    }

    ToggleTodo(id) -> {
      let new_todos =
        list.map(model.todos, fn(item) {
          case item.id == id {
            True -> TodoItem(..item, completed: !item.completed)
            False -> item
          }
        })
      #(Model(..model, todos: new_todos), effect.none())
    }

    DeleteTodo(id) -> {
      let new_todos = list.filter(model.todos, fn(item) { item.id != id })
      #(Model(..model, todos: new_todos), effect.none())
    }

    ClearCompleted -> {
      let new_todos =
        list.filter(model.todos, fn(item) { !item.completed })
      #(Model(..model, todos: new_todos), effect.none())
    }

    SetFilter(filter) -> {
      #(Model(..model, filter: filter), effect.none())
    }

    UpdateInput(value) -> {
      let new_form = form.set_value(model.input_form, "new_todo", value)
      #(Model(..model, input_form: new_form), effect.none())
    }
  }
}

/// Render the view.
pub fn view(model: Model) -> element.Node(Msg) {
  let active_count =
    list.length(list.filter(model.todos, fn(t) { !t.completed }))
  let completed_count =
    list.length(list.filter(model.todos, fn(t) { t.completed }))

  element.el("div", [element.attr("class", "todo-app")], [
    element.el("h1", [], [element.text("Beacon Todos")]),
    // Input form
    element.el("div", [element.attr("class", "todo-input")], [
      element.el(
        "input",
        [
          element.attr("type", "text"),
          element.attr("name", "new_todo"),
          element.attr("placeholder", "What needs to be done?"),
          element.attr(
            "value",
            form.get_value(model.input_form, "new_todo"),
          ),
          element.on("input", "update_input"),
        ],
        [],
      ),
      element.el(
        "button",
        [element.on("click", "add_todo")],
        [element.text("Add")],
      ),
    ]),
    // Validation errors
    render_form_errors(model.input_form),
    // Todo list
    element.el("ul", [element.attr("class", "todo-list")],
      list.map(visible_todos(model), fn(item) {
        render_todo_item(item)
      }),
    ),
    // Footer
    element.el("div", [element.attr("class", "todo-footer")], [
      element.text(
        int.to_string(active_count)
        <> " item(s) left",
      ),
      render_filters(model.filter),
      case completed_count > 0 {
        True ->
          element.el(
            "button",
            [element.on("click", "clear_completed")],
            [element.text("Clear completed")],
          )
        False -> element.el("span", [], [])
      },
    ]),
  ])
}

/// Render a single todo item with memo for performance.
fn render_todo_item(item: TodoItem) -> element.Node(Msg) {
  let class = case item.completed {
    True -> "todo-item completed"
    False -> "todo-item"
  }
  element.memo(
    "todo-" <> int.to_string(item.id),
    [item.text, case item.completed {
      True -> "t"
      False -> "f"
    }],
    element.el("li", [element.attr("class", class)], [
      element.el(
        "input",
        [
          element.attr("type", "checkbox"),
          element.on("click", "toggle_" <> int.to_string(item.id)),
        ],
        [],
      ),
      element.el("span", [], [element.text(item.text)]),
      element.el(
        "button",
        [
          element.attr("class", "delete"),
          element.on("click", "delete_" <> int.to_string(item.id)),
        ],
        [element.text("x")],
      ),
    ]),
  )
}

/// Render filter buttons.
fn render_filters(current: Filter) -> element.Node(Msg) {
  element.el("span", [element.attr("class", "filters")], [
    filter_button("All", All, current),
    filter_button("Active", Active, current),
    filter_button("Completed", Completed, current),
  ])
}

fn filter_button(
  label: String,
  filter: Filter,
  current: Filter,
) -> element.Node(Msg) {
  let class = case filter == current {
    True -> "filter-btn active"
    False -> "filter-btn"
  }
  let handler = case filter {
    All -> "filter_all"
    Active -> "filter_active"
    Completed -> "filter_completed"
  }
  element.el(
    "button",
    [element.attr("class", class), element.on("click", handler)],
    [element.text(label)],
  )
}

/// Get visible todos based on current filter.
fn visible_todos(model: Model) -> List(TodoItem) {
  case model.filter {
    All -> model.todos
    Active -> list.filter(model.todos, fn(t) { !t.completed })
    Completed -> list.filter(model.todos, fn(t) { t.completed })
  }
}

/// Render form validation errors.
fn render_form_errors(f: form.Form) -> element.Node(Msg) {
  case form.has_errors(f) {
    True -> {
      case form.get_field(f, "new_todo") {
        Ok(field) ->
          element.el("div", [element.attr("class", "error")],
            list.map(field.errors, fn(err) {
              element.el("span", [], [element.text(err)])
            }),
          )
        Error(Nil) -> element.el("span", [], [])
      }
    }
    False -> element.el("span", [], [])
  }
}

/// Decode client events.
pub fn decode_event(
  _name: String,
  handler_id: String,
  data: String,
  _path: String,
) -> Result(Msg, error.BeaconError) {
  case handler_id {
    "add_todo" -> Ok(AddTodo)
    "clear_completed" -> Ok(ClearCompleted)
    "filter_all" -> Ok(SetFilter(All))
    "filter_active" -> Ok(SetFilter(Active))
    "filter_completed" -> Ok(SetFilter(Completed))
    "update_input" -> {
      // Extract value from event data JSON
      let value = extract_input_value(data)
      Ok(UpdateInput(value: value))
    }
    _ -> {
      // Try toggle_N or delete_N
      case string.starts_with(handler_id, "toggle_") {
        True -> {
          let id_str = string.drop_start(handler_id, 7)
          case int.parse(id_str) {
            Ok(id) -> Ok(ToggleTodo(id: id))
            Error(Nil) ->
              Error(error.RuntimeError(
                reason: "Invalid toggle id: " <> id_str,
              ))
          }
        }
        False -> {
          case string.starts_with(handler_id, "delete_") {
            True -> {
              let id_str = string.drop_start(handler_id, 7)
              case int.parse(id_str) {
                Ok(id) -> Ok(DeleteTodo(id: id))
                Error(Nil) ->
                  Error(error.RuntimeError(
                    reason: "Invalid delete id: " <> id_str,
                  ))
              }
            }
            False ->
              Error(error.RuntimeError(
                reason: "Unknown handler: " <> handler_id,
              ))
          }
        }
      }
    }
  }
}

/// Extract input value from event data JSON like {"value":"text"}.
fn extract_input_value(data: String) -> String {
  // Simple extraction — look for "value":"..."
  case string.split(data, "\"value\":\"") {
    [_, rest] -> {
      case string.split(rest, "\"") {
        [value, ..] -> value
        _ -> ""
      }
    }
    _ -> ""
  }
}

/// Start the todo app.
pub fn start(port: Int) -> Result(Nil, error.BeaconError) {
  log.configure()
  log.info("todo", "Starting todo app on port " <> int.to_string(port))

  let config =
    runtime.RuntimeConfig(
      init: init,
      update: update,
      view: view,
      decode_event: option.Some(decode_event),
      serialize_model: option.None,
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None, on_notify: option.None,
    )
  case runtime.start(config) {
    Ok(runtime_subject) -> {
      let ssr_config =
        ssr.SsrConfig(
          init: init,
          view: view,
          secret_key: "todo-secret-key-change-in-production!!",
          title: "Beacon Todos",
          head_html: option.None,
        )
      let page = ssr.render_page(ssr_config)
      let transport_config =
        runtime.connect_transport_with_ssr(
          runtime_subject,
          port,
          option.Some(page.html),
        )
      case transport.start(transport_config) {
        Ok(_pid) -> {
          log.info("todo", "Todo app running on port " <> int.to_string(port))
          Ok(Nil)
        }
        Error(err) -> Error(err)
      }
    }
    Error(err) -> Error(err)
  }
}
