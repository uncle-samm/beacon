/// Multi-room chat — demonstrates:
/// - Per-connection runtimes (each tab = own username/room)
/// - Shared state via beacon/store (no FFI needed)
/// - PubSub for broadcasting to other users
/// - beacon.on_click, beacon.on_input — no decode_event

import beacon
import beacon/html
import beacon/store
import gleam/list
import gleam/string

/// A chat message.
pub type ChatMessage {
  ChatMessage(sender: String, text: String, room: String, id: Int)
}

/// Per-session model.
pub type Model {
  Model(
    username: String,
    username_input: String,
    has_username: Bool,
    current_room: String,
    input_text: String,
    available_rooms: List(String),
    visible_messages: List(ChatMessage),
  )
}

/// Messages.
pub type Msg {
  UpdateInput(String)
  UpdateUsername(String)
  SetUsername
  SendMessage
  SwitchRoom(String)
  NewMessageBroadcast
}

/// Initialize per-session model.
pub fn init() -> Model {
  Model(
    username: "",
    username_input: "",
    has_username: False,
    current_room: "general",
    input_text: "",
    available_rooms: ["general", "random", "help"],
    visible_messages: [],
  )
}

/// Create an update function that captures the shared message store.
pub fn make_update(
  messages: store.ListStore(ChatMessage),
) -> fn(Model, Msg) -> Model {
  fn(model: Model, msg: Msg) -> Model {
    case msg {
      UpdateInput(text) -> Model(..model, input_text: text)
      UpdateUsername(text) -> Model(..model, username_input: text)

      SetUsername -> {
        let name = string.trim(model.username_input)
        case string.is_empty(name) {
          True -> model
          False ->
            Model(
              ..model,
              username: name,
              has_username: True,
              visible_messages: store.get_all(messages, model.current_room),
            )
        }
      }

      SendMessage -> {
        let text = string.trim(model.input_text)
        case string.is_empty(text) {
          True -> model
          False -> {
            let message =
              ChatMessage(
                sender: model.username,
                text: text,
                room: model.current_room,
                id: unique_int(),
              )
            store.append(messages, model.current_room, message)
            // No manual broadcast needed — store.append auto-notifies watchers
            Model(
              ..model,
              input_text: "",
              visible_messages: store.get_all(messages, model.current_room),
            )
          }
        }
      }

      SwitchRoom(room) ->
        Model(
          ..model,
          current_room: room,
          visible_messages: store.get_all(messages, room),
        )

      NewMessageBroadcast ->
        Model(
          ..model,
          visible_messages: store.get_all(messages, model.current_room),
        )
    }
  }
}

/// Render the chat view.
pub fn view(model: Model) -> beacon.Node(Msg) {
  case model.has_username {
    False -> view_login(model)
    True -> view_chat(model)
  }
}

fn view_login(model: Model) -> beacon.Node(Msg) {
  html.div([html.class("chat-login")], [
    html.h1([], [html.text("Beacon Chat")]),
    html.p([], [html.text("Enter your name to join:")]),
    html.div([html.class("login-form")], [
      html.input([
        html.type_("text"),
        html.placeholder("Your name..."),
        html.value(model.username_input),
        beacon.on_input(UpdateUsername),
      ]),
      html.button([beacon.on_click(SetUsername)], [
        html.text("Join Chat"),
      ]),
    ]),
  ])
}

fn view_chat(model: Model) -> beacon.Node(Msg) {
  html.div([html.class("chat-app")], [
    // Sidebar
    html.div([html.class("chat-sidebar")], [
      html.h2([], [html.text("Rooms")]),
      html.ul(
        [],
        list.map(model.available_rooms, fn(room) {
          let cls = case room == model.current_room {
            True -> "room active"
            False -> "room"
          }
          html.li([html.class(cls)], [
            html.button([beacon.on_click(SwitchRoom(room))], [
              html.text("#" <> room),
            ]),
          ])
        }),
      ),
      html.p([html.class("username-display")], [
        html.text("You: " <> model.username),
      ]),
    ]),
    // Main
    html.div([html.class("chat-main")], [
      html.h2([], [html.text("#" <> model.current_room)]),
      html.div(
        [html.class("chat-messages")],
        case model.visible_messages {
          [] -> [
            html.p([html.class("empty")], [
              html.text("No messages yet. Say something!"),
            ]),
          ]
          msgs ->
            list.map(msgs, fn(m) {
              html.div([html.class("chat-message")], [
                html.strong([], [html.text(m.sender <> ": ")]),
                html.text(m.text),
              ])
            })
        },
      ),
      html.div([html.class("chat-input")], [
        html.input([
          html.type_("text"),
          html.placeholder("Type a message..."),
          html.value(model.input_text),
          beacon.on_input(UpdateInput),
        ]),
        html.button([beacon.on_click(SendMessage)], [
          html.text("Send"),
        ]),
      ]),
    ]),
  ])
}

/// Start the chat app.
pub fn start() {
  let messages = store.new_list("chat_messages")

  beacon.app(init, make_update(messages), view)
  |> beacon.title("Beacon Chat")
  |> beacon.watch_list(messages, fn() { NewMessageBroadcast })
  |> beacon.start(8080)
}

@external(erlang, "erlang", "unique_integer")
fn unique_int() -> Int
