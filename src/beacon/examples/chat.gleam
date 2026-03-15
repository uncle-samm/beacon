/// Multi-room, multi-user chat — demonstrates:
/// - Per-connection runtime (each tab gets its own MVU process)
/// - Shared state via ETS (message history accessible to all)
/// - PubSub for broadcasting new messages to all connected users
/// - Each user has their own session state (username, room, input)
///
/// Architecture:
///   Browser Tab A → Runtime A (Model: username="Alice", room="general")
///   Browser Tab B → Runtime B (Model: username="Bob", room="random")
///   Shared ETS table → all messages for all rooms
///   PubSub "chat:messages" → broadcasts new messages to all runtimes

import beacon/effect
import beacon/element
import beacon/error
import beacon/log
import beacon/pubsub
import gleam/list
import gleam/string

/// A single chat message.
pub type ChatMessage {
  ChatMessage(sender: String, text: String, room: String, id: Int)
}

/// Per-session model — each browser tab has its own instance.
/// Messages are NOT stored here — they're in the shared ETS store.
pub type Model {
  Model(
    username: String,
    username_input: String,
    has_username: Bool,
    current_room: String,
    input_text: String,
    available_rooms: List(String),
    /// Messages visible in the current view (pulled from shared store).
    visible_messages: List(ChatMessage),
  )
}

/// Messages.
pub type Msg {
  UpdateInput(text: String)
  UpdateUsername(text: String)
  SetUsername
  SendMessage
  SwitchRoom(room: String)
  /// A new message arrived via PubSub — refresh visible messages.
  NewMessageBroadcast
}

/// The shared message store — backed by ETS so all runtimes can access it.
pub type ChatStore

/// Initialize the shared chat store. Call once at app startup.
pub fn init_store(name: String) -> ChatStore {
  log.info("chat", "Initializing shared message store")
  chat_ets_new(name)
}

/// Add a message to the shared store.
pub fn store_message(store: ChatStore, msg: ChatMessage) -> Nil {
  chat_ets_append(store, msg.room, msg)
}

/// Get all messages for a room from the shared store.
pub fn get_messages(store: ChatStore, room: String) -> List(ChatMessage) {
  chat_ets_get_messages(store, room)
}

/// Initialize per-session model.
pub fn init() -> #(Model, effect.Effect(Msg)) {
  let rooms = ["general", "random", "help"]
  #(
    Model(
      username: "",
      username_input: "",
      has_username: False,
      current_room: "general",
      input_text: "",
      available_rooms: rooms,
      visible_messages: [],
    ),
    effect.none(),
  )
}

/// Update per-session model.
/// The `store` is captured in a closure when wiring up the app.
pub fn make_update(
  store: ChatStore,
) -> fn(Model, Msg) -> #(Model, effect.Effect(Msg)) {
  fn(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
    case msg {
      UpdateInput(text) -> #(Model(..model, input_text: text), effect.none())

      UpdateUsername(text) -> #(
        Model(..model, username_input: text),
        effect.none(),
      )

      SetUsername -> {
        let name = string.trim(model.username_input)
        case string.is_empty(name) {
          True -> #(model, effect.none())
          False -> {
            log.info("chat", name <> " joined")
            let messages = get_messages(store, model.current_room)
            #(
              Model(
                ..model,
                username: name,
                has_username: True,
                visible_messages: messages,
              ),
              effect.none(),
            )
          }
        }
      }

      SendMessage -> {
        let text = string.trim(model.input_text)
        case string.is_empty(text) {
          True -> #(model, effect.none())
          False -> {
            let message =
              ChatMessage(
                sender: model.username,
                text: text,
                room: model.current_room,
                id: erlang_unique_integer(),
              )
            // Store in shared ETS
            store_message(store, message)
            log.info(
              "chat",
              "[#" <> model.current_room <> "] " <> model.username <> ": " <> text,
            )
            // Broadcast to all connected users via PubSub
            pubsub.broadcast("chat:messages", NewMessageBroadcast)
            // Refresh visible messages
            let messages = get_messages(store, model.current_room)
            #(
              Model(..model, input_text: "", visible_messages: messages),
              effect.none(),
            )
          }
        }
      }

      SwitchRoom(room) -> {
        let messages = get_messages(store, room)
        #(
          Model(..model, current_room: room, visible_messages: messages),
          effect.none(),
        )
      }

      NewMessageBroadcast -> {
        // Another user sent a message — refresh our visible messages
        let messages = get_messages(store, model.current_room)
        #(Model(..model, visible_messages: messages), effect.none())
      }
    }
  }
}

/// Render the chat view.
pub fn view(model: Model) -> element.Node(Msg) {
  case model.has_username {
    False -> view_login(model)
    True -> view_chat(model)
  }
}

fn view_login(model: Model) -> element.Node(Msg) {
  element.el("div", [element.attr("class", "chat-login")], [
    element.el("h1", [], [element.text("Beacon Chat")]),
    element.el("p", [], [
      element.text("Enter your name to join:"),
    ]),
    element.el("div", [element.attr("class", "login-form")], [
      element.el(
        "input",
        [
          element.attr("type", "text"),
          element.attr("placeholder", "Your name..."),
          element.attr("value", model.username_input),
          element.on("input", "update_username"),
        ],
        [],
      ),
      element.el(
        "button",
        [element.on("click", "set_username")],
        [element.text("Join Chat")],
      ),
    ]),
  ])
}

fn view_chat(model: Model) -> element.Node(Msg) {
  element.el("div", [element.attr("class", "chat-app")], [
    // Sidebar
    element.el("div", [element.attr("class", "chat-sidebar")], [
      element.el("h2", [], [element.text("Rooms")]),
      element.el(
        "ul",
        [],
        list.map(model.available_rooms, fn(room) {
          let class = case room == model.current_room {
            True -> "room active"
            False -> "room"
          }
          element.el("li", [element.attr("class", class)], [
            element.el(
              "button",
              [element.on("click", "room_" <> room)],
              [element.text("#" <> room)],
            ),
          ])
        }),
      ),
      element.el("p", [element.attr("class", "username-display")], [
        element.text("You: " <> model.username),
      ]),
    ]),
    // Main
    element.el("div", [element.attr("class", "chat-main")], [
      element.el("h2", [], [
        element.text("#" <> model.current_room),
      ]),
      element.el(
        "div",
        [element.attr("class", "chat-messages")],
        case model.visible_messages {
          [] -> [
            element.el("p", [element.attr("class", "empty")], [
              element.text("No messages yet. Say something!"),
            ]),
          ]
          msgs ->
            list.map(msgs, fn(msg) {
              element.el("div", [element.attr("class", "chat-message")], [
                element.el("strong", [], [
                  element.text(msg.sender <> ": "),
                ]),
                element.text(msg.text),
              ])
            })
        },
      ),
      element.el("div", [element.attr("class", "chat-input")], [
        element.el(
          "input",
          [
            element.attr("type", "text"),
            element.attr("placeholder", "Type a message..."),
            element.attr("value", model.input_text),
            element.on("input", "update_input"),
          ],
          [],
        ),
        element.el(
          "button",
          [element.on("click", "send_message")],
          [element.text("Send")],
        ),
      ]),
    ]),
  ])
}

/// Decode client events.
pub fn decode_event(
  _name: String,
  handler_id: String,
  data: String,
  _path: String,
) -> Result(Msg, error.BeaconError) {
  case handler_id {
    "update_input" -> Ok(UpdateInput(text: extract_value(data)))
    "update_username" -> Ok(UpdateUsername(text: extract_value(data)))
    "set_username" -> Ok(SetUsername)
    "send_message" -> Ok(SendMessage)
    _ -> {
      case string.starts_with(handler_id, "room_") {
        True -> Ok(SwitchRoom(room: string.drop_start(handler_id, 5)))
        False ->
          Error(error.RuntimeError(
            reason: "Unknown handler: " <> handler_id,
          ))
      }
    }
  }
}

fn extract_value(data: String) -> String {
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

// --- ETS FFI for shared message store ---

@external(erlang, "beacon_chat_ffi", "new_store")
fn chat_ets_new(name: String) -> ChatStore

@external(erlang, "beacon_chat_ffi", "append_message")
fn chat_ets_append(store: ChatStore, room: String, msg: ChatMessage) -> Nil

@external(erlang, "beacon_chat_ffi", "get_messages")
fn chat_ets_get_messages(store: ChatStore, room: String) -> List(ChatMessage)

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int
