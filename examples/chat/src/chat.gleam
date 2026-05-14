/// Multi-room chat with presence — demonstrates:
/// - Per-connection runtimes (each tab = own username/room)
/// - Shared state via beacon/store (no FFI needed)
/// - Dynamic PubSub subscriptions (only notified for your current room)
/// - Presence tracking (who's online in each room)
/// - Typing indicators (ephemeral PubSub notifications)
/// - beacon.on_click, beacon.on_input — no decode_event
import beacon
import beacon/effect
import beacon/html
import beacon/pubsub
import beacon/store
import gleam/int
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
    /// Users currently in the current room
    online_users: List(String),
    /// Unique session ID for presence tracking
    session_id: Int,
    /// Who is currently typing (from PubSub)
    typing_user: String,
  )
}

/// Messages.
pub type Msg {
  UpdateInput(String)
  UpdateUsername(String)
  SetUsername
  SendMessage
  SwitchRoom(String)
  RoomUpdated(String)
  LoadMessages(List(ChatMessage))
  ClearTypingIndicator
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
    online_users: [],
    session_id: unique_int(),
    typing_user: "",
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
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
        False -> #(
          Model(..model, username: name, has_username: True, online_users: [
            name,
          ]),
          effect.none(),
        )
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
              id: model.session_id + list.length(model.visible_messages),
            )
          #(
            Model(
              ..model,
              input_text: "",
              visible_messages: list.append(model.visible_messages, [message]),
            ),
            effect.none(),
          )
        }
      }
    }

    SwitchRoom(room) -> #(
      Model(
        ..model,
        current_room: room,
        visible_messages: [],
        online_users: case string.is_empty(model.username) {
          True -> []
          False -> [model.username]
        },
        typing_user: "",
      ),
      effect.none(),
    )

    RoomUpdated(topic) -> {
      case string.starts_with(topic, "typing:") {
        True -> #(
          Model(..model, typing_user: "Someone"),
          effect.after(2000, fn() { ClearTypingIndicator }),
        )
        False -> #(model, effect.none())
      }
    }

    LoadMessages(messages) -> #(
      Model(..model, visible_messages: messages),
      effect.none(),
    )

    ClearTypingIndicator -> #(Model(..model, typing_user: ""), effect.none())
  }
}

fn make_on_update(
  messages: store.ListStore(ChatMessage),
  presence: store.ListStore(String),
) -> fn(Model, Msg) -> effect.Effect(Msg) {
  fn(model: Model, msg: Msg) -> effect.Effect(Msg) {
    case msg {
      UpdateInput(text) ->
        case string.is_empty(text) {
          True -> effect.none()
          False ->
            effect.from(fn(_dispatch) {
              pubsub.broadcast("typing:" <> model.current_room, Nil)
            })
        }
      SetUsername ->
        effect.from(fn(dispatch) {
          let session_key =
            model.current_room <> ":" <> int.to_string(model.session_id)
          store.append(presence, session_key, model.username)
          dispatch(LoadMessages(store.get_all(messages, model.current_room)))
        })
      SwitchRoom(room) ->
        effect.from(fn(dispatch) {
          dispatch(LoadMessages(store.get_all(messages, room)))
        })
      SendMessage ->
        effect.from(fn(_dispatch) {
          case list.last(model.visible_messages) {
            Ok(message) ->
              store.append_notify(
                messages,
                model.current_room,
                message,
                "room:",
              )
            Error(Nil) -> Nil
          }
        })
      RoomUpdated(topic) ->
        case string.starts_with(topic, "room:") {
          True ->
            effect.from(fn(dispatch) {
              let room = string.drop_start(topic, 5)
              case room == model.current_room {
                True -> dispatch(LoadMessages(store.get_all(messages, room)))
                False -> Nil
              }
            })
          False -> effect.none()
        }
      _ -> effect.none()
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
      // Online users
      html.div([html.style("margin-top:1rem;font-size:0.85rem;color:#666")], [
        html.text(
          "Online: "
          <> case model.online_users {
            [] -> "just you"
            users -> string.join(users, ", ")
          },
        ),
      ]),
    ]),
    // Main
    html.div([html.class("chat-main")], [
      html.h2([], [html.text("#" <> model.current_room)]),
      html.div([html.class("chat-messages")], case model.visible_messages {
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
      }),
      // Typing indicator
      case string.is_empty(model.typing_user) {
        True -> html.text("")
        False ->
          html.p([html.style("color:#999;font-size:0.85rem;margin:4px 0")], [
            html.text(model.typing_user <> " is typing..."),
          ])
      },
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

pub fn main() {
  start()
}

/// Start the chat app.
pub fn start() {
  let messages = store.new_list("chat_messages")
  let presence = store.new_list("chat_presence")

  beacon.app_with_effects(fn() { #(init(), effect.none()) }, update, view)
  |> beacon.on_update(make_on_update(messages, presence))
  |> beacon.title("Beacon Chat")
  |> beacon.subscriptions(fn(model: Model) {
    // Subscribe to room messages AND typing indicators.
    // When user switches rooms, framework auto-unsubscribes from old.
    ["room:" <> model.current_room, "typing:" <> model.current_room]
  })
  |> beacon.on_notify(fn(topic) { RoomUpdated(topic) })
  |> beacon.start(8080)
}

@external(erlang, "erlang", "unique_integer")
fn unique_int() -> Int
