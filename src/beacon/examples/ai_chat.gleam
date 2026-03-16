/// AI Chat — demonstrates:
/// - app_with_effects for async server functions
/// - beacon.on_click + beacon.on_input (no decode_event)
/// - Loading state while "AI" responds

import beacon
import beacon/effect
import beacon/html
import beacon/server_fn
import gleam/list
import gleam/string

pub type Message {
  Message(role: Role, content: String)
}

pub type Role {
  User
  Assistant
}

pub type Model {
  Model(messages: List(Message), input_text: String, is_loading: Bool)
}

pub type Msg {
  UpdateInput(String)
  SendPrompt
  AiResponseReceived(String)
}

pub fn init() -> #(Model, effect.Effect(Msg)) {
  #(
    Model(
      messages: [
        Message(
          role: Assistant,
          content: "Hello! I'm a demo AI. I echo your messages back. In a real app, plug in the Anthropic SDK here.",
        ),
      ],
      input_text: "",
      is_loading: False,
    ),
    effect.none(),
  )
}

pub fn update(
  model: Model,
  msg: Msg,
) -> #(Model, effect.Effect(Msg)) {
  case msg {
    UpdateInput(text) -> #(Model(..model, input_text: text), effect.none())

    SendPrompt -> {
      let text = string.trim(model.input_text)
      case string.is_empty(text) {
        True -> #(model, effect.none())
        False -> {
          let user_msg = Message(role: User, content: text)
          #(
            Model(
              messages: list.append(model.messages, [user_msg]),
              input_text: "",
              is_loading: True,
            ),
            server_fn.call_async(
              fn() { simulate_ai(text) },
              AiResponseReceived,
            ),
          )
        }
      }
    }

    AiResponseReceived(response) -> {
      let ai_msg = Message(role: Assistant, content: response)
      #(
        Model(
          ..model,
          messages: list.append(model.messages, [ai_msg]),
          is_loading: False,
        ),
        effect.none(),
      )
    }
  }
}

fn simulate_ai(prompt: String) -> String {
  sleep(500)
  let lower = string.lowercase(prompt)
  let is_hello = string.contains(lower, "hello")
  let is_gleam = string.contains(lower, "gleam")
  let is_beacon = string.contains(lower, "beacon")
  case is_hello, is_gleam, is_beacon {
    True, _, _ -> "Hello! How can I help you?"
    _, True, _ -> "Gleam is a type-safe language on the BEAM!"
    _, _, True -> "Beacon is a full-stack Gleam web framework."
    _, _, _ -> "You said: \"" <> prompt <> "\""
  }
}

@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.div([html.class("ai-chat")], [
    html.h1([], [html.text("Beacon AI Chat")]),
    html.div(
      [html.class("ai-messages")],
      list.append(
        list.map(model.messages, fn(msg) {
          let cls = case msg.role {
            User -> "ai-message user"
            Assistant -> "ai-message assistant"
          }
          let role_label = case msg.role {
            User -> "You"
            Assistant -> "AI"
          }
          html.div([html.class(cls)], [
            html.div([html.class("ai-role")], [html.text(role_label)]),
            html.div([html.class("ai-content")], [html.text(msg.content)]),
          ])
        }),
        case model.is_loading {
          True -> [
            html.div([html.class("ai-message assistant loading")], [
              html.text("Thinking..."),
            ]),
          ]
          False -> []
        },
      ),
    ),
    html.div([html.class("ai-input")], [
      html.input([
        html.type_("text"),
        html.placeholder("Ask me anything..."),
        html.value(model.input_text),
        beacon.on_input(UpdateInput),
      ]),
      html.button([beacon.on_click(SendPrompt)], [html.text("Send")]),
    ]),
  ])
}
