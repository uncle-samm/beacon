/// AI Chat — demonstrates:
/// - Server-side streaming without exposing secrets to the client
/// - Smooth character-by-character streaming (text buffered, dripped to client)
/// - Multi-turn conversation with full history
/// - effect.from for spawning async work that dispatches to the runtime
import beacon
import beacon/effect
import beacon/html
import beacon/log
import gleam/erlang/process
import gleam/list
import gleam/string

// --- Types ---

pub type ChatMessage {
  ChatMessage(role: Role, content: String)
}

pub type Role {
  User
  Assistant
}

pub type Model {
  Model(
    messages: List(ChatMessage),
    input_text: String,
    is_streaming: Bool,
    streaming_text: String,
  )
}

pub type Msg {
  UpdateInput(String)
  SendPrompt
  /// A single character from the drip-feed
  CharDelta(String)
  StreamDone
  StreamError(String)
}

// --- Init ---

pub fn init() -> #(Model, effect.Effect(Msg)) {
  #(
    Model(
      messages: [
        ChatMessage(
          role: Assistant,
          content: "Hello! This example streams a deterministic server-side response so CI can test effect dispatch without external services.",
        ),
      ],
      input_text: "",
      is_streaming: False,
      streaming_text: "",
    ),
    effect.none(),
  )
}

// --- Update ---

pub fn update(
  model: Model,
  _local: Nil,
  _server: Nil,
  msg: Msg,
) -> #(Model, Nil, Nil) {
  let model = case msg {
    UpdateInput(text) -> Model(..model, input_text: text)

    SendPrompt -> {
      let text = string.trim(model.input_text)
      case string.is_empty(text) || model.is_streaming {
        True -> model
        False -> {
          let user_msg = ChatMessage(role: User, content: text)
          let new_messages = list.append(model.messages, [user_msg])
          Model(
            messages: new_messages,
            input_text: "",
            is_streaming: True,
            streaming_text: "",
          )
        }
      }
    }

    CharDelta(ch) -> Model(..model, streaming_text: model.streaming_text <> ch)

    StreamDone -> {
      let ai_msg = ChatMessage(role: Assistant, content: model.streaming_text)
      Model(
        ..model,
        messages: list.append(model.messages, [ai_msg]),
        is_streaming: False,
        streaming_text: "",
      )
    }

    StreamError(err) -> {
      let error_msg = ChatMessage(role: Assistant, content: "Error: " <> err)
      Model(
        ..model,
        messages: list.append(model.messages, [error_msg]),
        is_streaming: False,
        streaming_text: "",
      )
    }
  }
  #(model, Nil, Nil)
}

fn after_update(state: #(Model, Nil, Nil), msg: Msg) -> effect.Effect(Msg) {
  let model = state.0
  case msg, model.is_streaming {
    SendPrompt, True -> start_streaming(model.messages)
    _, _ -> effect.none()
  }
}

// --- AI Streaming with Character Drip ---

fn start_streaming(messages: List(ChatMessage)) -> effect.Effect(Msg) {
  effect.from(fn(dispatch) {
    // Spawn dripper process — it creates its own Subject, spawns the fetcher,
    // and drips characters to the runtime via dispatch.
    let _ =
      process.spawn(fn() {
        // Subject created inside the dripper process — belongs to this process
        let char_subject = process.new_subject()

        // Spawn fetcher that sends token chunks to our subject
        let _ = process.spawn(fn() { fetch_ai_stream(messages, char_subject) })

        // Drip characters to the runtime
        drip_characters(char_subject, dispatch, "")
      })
    Nil
  })
}

/// Builds a deterministic stream and sends it to the subject.
/// Sends "" (empty string) when done, or an error string prefixed with "ERR:".
fn fetch_ai_stream(
  messages: List(ChatMessage),
  subject: process.Subject(String),
) -> Nil {
  let prompt = latest_user_text(messages, "your message")
  let response =
    "Server stream received: "
    <> prompt
    <> ". Beacon keeps this work on the server and sends state updates to the client."

  log.info("ai_chat", "Starting deterministic response stream")
  process.send(subject, response)
  sleep(20)
  process.send(subject, "")
  Nil
}

/// Reads token chunks from the subject and dispatches small character batches
/// with delays for a smooth typing effect.
fn drip_characters(
  subject: process.Subject(String),
  dispatch: fn(Msg) -> Nil,
  buffer: String,
) -> Nil {
  // If buffer has characters, drip a small batch (3-5 chars)
  case string.is_empty(buffer) {
    False -> {
      let #(batch, rest) = take_graphemes(buffer, 3)
      dispatch(CharDelta(batch))
      sleep(30)
      drip_characters(subject, dispatch, rest)
    }
    True -> {
      // Buffer empty — try to get more from the subject
      let selector =
        process.new_selector()
        |> process.select(subject)
      case process.selector_receive(selector, 5000) {
        Ok(chunk) -> {
          case chunk {
            "" -> {
              dispatch(StreamDone)
              Nil
            }
            _ -> {
              case string.starts_with(chunk, "ERR:") {
                True -> {
                  let err = string.drop_start(chunk, 4)
                  dispatch(StreamError(err))
                  Nil
                }
                False -> drip_characters(subject, dispatch, chunk)
              }
            }
          }
        }
        Error(_) -> {
          dispatch(StreamDone)
          Nil
        }
      }
    }
  }
}

/// Take up to n graphemes from a string, return #(taken, rest).
fn take_graphemes(s: String, n: Int) -> #(String, String) {
  take_graphemes_loop(s, n, "")
}

fn take_graphemes_loop(
  s: String,
  remaining: Int,
  acc: String,
) -> #(String, String) {
  case remaining <= 0 {
    True -> #(acc, s)
    False ->
      case string.pop_grapheme(s) {
        Ok(#(ch, rest)) -> take_graphemes_loop(rest, remaining - 1, acc <> ch)
        Error(_) -> {
          log.debug("ai_chat", "Reached end of string while taking graphemes")
          #(acc, "")
        }
      }
  }
}

fn latest_user_text(messages: List(ChatMessage), default_text: String) -> String {
  case messages {
    [] -> default_text
    [message, ..rest] -> {
      let next = case message.role {
        User -> message.content
        Assistant -> default_text
      }
      latest_user_text(rest, next)
    }
  }
}

@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil

// --- Start ---

pub fn main() {
  beacon.app(init, beacon.no_local, beacon.no_server, update, view)
  |> beacon.on_update(after_update)
  |> beacon.title("Beacon AI Chat")
  |> beacon.start(8080)
}

// --- View ---

pub fn view(model: Model, _local: Nil) -> beacon.Node(Msg) {
  html.div(
    [
      html.style(
        "font-family:system-ui;max-width:600px;margin:2rem auto;padding:0 1rem",
      ),
    ],
    [
      html.h1([html.style("margin-bottom:1rem")], [
        html.text("Beacon AI Chat"),
      ]),
      html.div(
        [
          html.style(
            "border:1px solid #e0e0e0;border-radius:8px;padding:1rem;min-height:300px;max-height:500px;overflow-y:auto;margin-bottom:1rem;background:#fafafa",
          ),
        ],
        list.append(
          list.map(model.messages, view_message),
          case model.is_streaming {
            True -> [view_streaming(model.streaming_text)]
            False -> []
          },
        ),
      ),
      html.div([html.style("display:flex;gap:8px")], [
        html.input([
          html.type_("text"),
          html.placeholder("Ask me anything..."),
          html.value(model.input_text),
          beacon.on_input(UpdateInput),
          html.style(
            "flex:1;padding:10px;border:1px solid #ddd;border-radius:8px;font-size:14px",
          ),
        ]),
        html.button(
          [
            beacon.on_click(SendPrompt),
            html.style(
              "padding:10px 20px;background:"
              <> case model.is_streaming {
                True -> "#ccc"
                False -> "#1976d2"
              }
              <> ";color:white;border:none;border-radius:8px;cursor:pointer;font-size:14px;font-weight:500",
            ),
          ],
          [
            html.text(case model.is_streaming {
              True -> "..."
              False -> "Send"
            }),
          ],
        ),
      ]),
    ],
  )
}

fn view_message(msg: ChatMessage) -> beacon.Node(Msg) {
  let #(bg, align, label) = case msg.role {
    User -> #("#e3f2fd", "flex-end", "You")
    Assistant -> #("#f5f5f5", "flex-start", "AI")
  }
  html.div(
    [
      html.style(
        "display:flex;flex-direction:column;align-items:"
        <> align
        <> ";margin-bottom:0.75rem",
      ),
    ],
    [
      html.div([html.style("font-size:0.75rem;color:#888;margin-bottom:2px")], [
        html.text(label),
      ]),
      html.div(
        [
          html.style(
            "background:"
            <> bg
            <> ";padding:8px 14px;border-radius:12px;max-width:80%;white-space:pre-wrap;line-height:1.4",
          ),
        ],
        [html.text(msg.content)],
      ),
    ],
  )
}

fn view_streaming(text: String) -> beacon.Node(Msg) {
  html.div(
    [
      html.style(
        "display:flex;flex-direction:column;align-items:flex-start;margin-bottom:0.75rem",
      ),
    ],
    [
      html.div([html.style("font-size:0.75rem;color:#888;margin-bottom:2px")], [
        html.text("AI"),
      ]),
      html.div(
        [
          html.style(
            "background:#f5f5f5;padding:8px 14px;border-radius:12px;max-width:80%;white-space:pre-wrap;line-height:1.4",
          ),
        ],
        [
          html.text(case string.is_empty(text) {
            True -> "Thinking..."
            False -> text <> "▊"
          }),
        ],
      ),
    ],
  )
}
