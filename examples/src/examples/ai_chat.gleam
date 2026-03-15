/// AI Chat — demonstrates:
/// - Server functions (async) for calling an AI API
/// - Streaming responses via effect.background
/// - Loading states
/// - Message history

import beacon/effect
import beacon/element
import beacon/error
import beacon/log
import beacon/server_fn
import gleam/list
import gleam/string

/// A chat message with a role (user or assistant).
pub type Message {
  Message(role: Role, content: String)
}

pub type Role {
  User
  Assistant
}

/// The app model.
pub type Model {
  Model(
    messages: List(Message),
    input_text: String,
    is_loading: Bool,
    next_id: Int,
  )
}

/// Messages.
pub type Msg {
  UpdateInput(text: String)
  SendPrompt
  AiResponseReceived(response: String)
  AiError(reason: String)
}

/// Initialize.
pub fn init() -> #(Model, effect.Effect(Msg)) {
  #(
    Model(
      messages: [
        Message(
          role: Assistant,
          content: "Hello! I'm a demo AI assistant. I don't actually call an API — I echo your message back. In a real app, you'd plug in the Anthropic SDK here.",
        ),
      ],
      input_text: "",
      is_loading: False,
      next_id: 1,
    ),
    effect.none(),
  )
}

/// Update.
pub fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    UpdateInput(text) -> #(Model(..model, input_text: text), effect.none())

    SendPrompt -> {
      let text = string.trim(model.input_text)
      case string.is_empty(text) {
        True -> #(model, effect.none())
        False -> {
          let user_msg = Message(role: User, content: text)
          let new_model =
            Model(
              ..model,
              messages: list.append(model.messages, [user_msg]),
              input_text: "",
              is_loading: True,
            )
          log.info("ai_chat", "User: " <> text)
          // Call the "AI" asynchronously
          let ai_effect =
            server_fn.call_async(
              fn() { simulate_ai_response(text) },
              fn(response) { AiResponseReceived(response: response) },
            )
          #(new_model, ai_effect)
        }
      }
    }

    AiResponseReceived(response) -> {
      let ai_msg = Message(role: Assistant, content: response)
      log.info("ai_chat", "AI: " <> response)
      #(
        Model(
          ..model,
          messages: list.append(model.messages, [ai_msg]),
          is_loading: False,
        ),
        effect.none(),
      )
    }

    AiError(reason) -> {
      let err_msg =
        Message(role: Assistant, content: "Error: " <> reason)
      #(
        Model(
          ..model,
          messages: list.append(model.messages, [err_msg]),
          is_loading: False,
        ),
        effect.none(),
      )
    }
  }
}

/// Simulate an AI response. In a real app, this would call the Anthropic API.
/// This runs on the server in a background process.
fn simulate_ai_response(prompt: String) -> String {
  // Simulate network latency
  sleep(500)
  // Echo-based "AI" response
  let lower = string.lowercase(prompt)
  let is_hello = string.contains(lower, "hello")
  let is_gleam = string.contains(lower, "gleam")
  let is_beacon = string.contains(lower, "beacon")
  let is_help = string.contains(lower, "help")
  case is_hello, is_gleam, is_beacon, is_help {
    True, _, _, _ -> "Hello! How can I help you today?"
    _, True, _, _ ->
      "Gleam is a type-safe language that runs on the BEAM! It's great for building reliable systems."
    _, _, True, _ ->
      "Beacon is a full-stack Gleam web framework with LiveView-style server rendering, WebSocket transport, and MVU architecture."
    _, _, _, True ->
      "I can answer questions about Gleam, Beacon, or anything else. Just ask!"
    _, _, _, _ ->
      "You said: \""
      <> prompt
      <> "\". In a real app, this would be an AI-generated response from the Anthropic API."
  }
}

@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil

/// Render the AI chat view.
pub fn view(model: Model) -> element.Node(Msg) {
  element.el("div", [element.attr("class", "ai-chat")], [
    element.el("h1", [], [element.text("Beacon AI Chat")]),
    // Message list
    element.el(
      "div",
      [element.attr("class", "ai-messages")],
      list.append(
        list.map(model.messages, fn(msg) {
          let class = case msg.role {
            User -> "ai-message user"
            Assistant -> "ai-message assistant"
          }
          let role_label = case msg.role {
            User -> "You"
            Assistant -> "AI"
          }
          element.el("div", [element.attr("class", class)], [
            element.el("div", [element.attr("class", "ai-role")], [
              element.text(role_label),
            ]),
            element.el("div", [element.attr("class", "ai-content")], [
              element.text(msg.content),
            ]),
          ])
        }),
        case model.is_loading {
          True -> [
            element.el(
              "div",
              [element.attr("class", "ai-message assistant loading")],
              [element.text("Thinking...")],
            ),
          ]
          False -> []
        },
      ),
    ),
    // Input
    element.el("div", [element.attr("class", "ai-input")], [
      element.el(
        "input",
        [
          element.attr("type", "text"),
          element.attr("placeholder", "Ask me anything..."),
          element.attr("value", model.input_text),
          element.on("input", "update_input"),
        ],
        [],
      ),
      element.el(
        "button",
        [element.on("click", "send_prompt")],
        [element.text("Send")],
      ),
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
    "send_prompt" -> Ok(SendPrompt)
    _ ->
      Error(error.RuntimeError(reason: "Unknown handler: " <> handler_id))
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
