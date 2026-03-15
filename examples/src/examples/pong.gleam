/// Pong game — demonstrates:
/// - Server-side game loop via effects (tick every 16ms)
/// - Real-time input handling (paddle movement)
/// - Game state management (ball physics, scoring)
/// - All game logic runs on the server — client is just a renderer

import beacon/effect
import beacon/element
import beacon/error
import gleam/int

/// Game constants.
const width = 600

const height = 400

const paddle_height = 80

const paddle_width = 10

const paddle_speed = 8

const ball_size = 10

const initial_ball_speed = 4

/// The game model.
pub type Model {
  Model(
    /// Left paddle Y position (center).
    left_y: Int,
    /// Right paddle Y position (center).
    right_y: Int,
    /// Ball X position.
    ball_x: Int,
    /// Ball Y position.
    ball_y: Int,
    /// Ball X velocity.
    ball_dx: Int,
    /// Ball Y velocity.
    ball_dy: Int,
    /// Left player score.
    left_score: Int,
    /// Right player score.
    right_score: Int,
    /// Whether the game is running.
    running: Bool,
    /// Tick counter for game loop.
    tick: Int,
  )
}

/// Game messages.
pub type Msg {
  /// Move left paddle up.
  LeftUp
  /// Move left paddle down.
  LeftDown
  /// Move right paddle up.
  RightUp
  /// Move right paddle down.
  RightDown
  /// Game tick — advance ball, check collisions.
  Tick
  /// Start/restart the game.
  StartGame
  /// Pause the game.
  PauseGame
}

/// Initialize the game.
pub fn init() -> #(Model, effect.Effect(Msg)) {
  #(new_game(), effect.none())
}

/// Create a fresh game state.
fn new_game() -> Model {
  Model(
    left_y: height / 2,
    right_y: height / 2,
    ball_x: width / 2,
    ball_y: height / 2,
    ball_dx: initial_ball_speed,
    ball_dy: initial_ball_speed / 2,
    left_score: 0,
    right_score: 0,
    running: False,
    tick: 0,
  )
}

/// Update the game state.
pub fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    LeftUp -> {
      let new_y = int.max(paddle_height / 2, model.left_y - paddle_speed)
      #(Model(..model, left_y: new_y), effect.none())
    }

    LeftDown -> {
      let new_y =
        int.min(height - paddle_height / 2, model.left_y + paddle_speed)
      #(Model(..model, left_y: new_y), effect.none())
    }

    RightUp -> {
      let new_y = int.max(paddle_height / 2, model.right_y - paddle_speed)
      #(Model(..model, right_y: new_y), effect.none())
    }

    RightDown -> {
      let new_y =
        int.min(height - paddle_height / 2, model.right_y + paddle_speed)
      #(Model(..model, right_y: new_y), effect.none())
    }

    Tick -> {
      case model.running {
        False -> #(model, effect.none())
        True -> {
          let new_model = advance_ball(model)
          // Schedule next tick via a background effect
          let tick_effect =
            effect.background(fn(dispatch) {
              sleep(16)
              dispatch(Tick)
            })
          #(new_model, tick_effect)
        }
      }
    }

    StartGame -> {
      let model = case model.running {
        True -> model
        False ->
          Model(
            ..model,
            running: True,
            ball_x: width / 2,
            ball_y: height / 2,
            ball_dx: initial_ball_speed,
            ball_dy: 2,
          )
      }
      // Start the game loop
      let tick_effect =
        effect.background(fn(dispatch) {
          sleep(16)
          dispatch(Tick)
        })
      #(model, tick_effect)
    }

    PauseGame -> #(Model(..model, running: False), effect.none())
  }
}

/// Advance the ball one frame, handling collisions.
fn advance_ball(model: Model) -> Model {
  let new_x = model.ball_x + model.ball_dx
  let new_y = model.ball_y + model.ball_dy

  // Top/bottom wall collision
  let new_dy = case new_y <= ball_size || new_y >= height - ball_size {
    True -> -model.ball_dy
    False -> model.ball_dy
  }
  let new_y = int.clamp(new_y + new_dy - model.ball_dy, ball_size, height - ball_size)

  // Left paddle collision
  let #(new_dx, new_x) = case
    new_x <= paddle_width + ball_size
    && new_y >= model.left_y - paddle_height / 2
    && new_y <= model.left_y + paddle_height / 2
  {
    True -> #(int.absolute_value(model.ball_dx), paddle_width + ball_size + 1)
    False -> #(model.ball_dx, new_x)
  }

  // Right paddle collision
  let #(new_dx, new_x) = case
    new_x >= width - paddle_width - ball_size
    && new_y >= model.right_y - paddle_height / 2
    && new_y <= model.right_y + paddle_height / 2
  {
    True -> #(-int.absolute_value(new_dx), width - paddle_width - ball_size - 1)
    False -> #(new_dx, new_x)
  }

  // Scoring — ball passed a paddle
  case new_x {
    x if x <= 0 ->
      // Right scores
      Model(
        ..model,
        right_score: model.right_score + 1,
        ball_x: width / 2,
        ball_y: height / 2,
        ball_dx: initial_ball_speed,
        ball_dy: 2,
        tick: model.tick + 1,
      )
    x if x >= width ->
      // Left scores
      Model(
        ..model,
        left_score: model.left_score + 1,
        ball_x: width / 2,
        ball_y: height / 2,
        ball_dx: -initial_ball_speed,
        ball_dy: 2,
        tick: model.tick + 1,
      )
    _ ->
      Model(
        ..model,
        ball_x: new_x,
        ball_y: new_y,
        ball_dx: new_dx,
        ball_dy: new_dy,
        tick: model.tick + 1,
      )
  }
}

@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil

/// Render the game view.
/// Uses inline SVG for the game canvas — no external graphics needed.
pub fn view(model: Model) -> element.Node(Msg) {
  element.el("div", [element.attr("class", "pong-game")], [
    element.el("h1", [], [element.text("Beacon Pong")]),
    // Score display
    element.el("div", [element.attr("class", "pong-score")], [
      element.text(
        int.to_string(model.left_score)
        <> " - "
        <> int.to_string(model.right_score),
      ),
    ]),
    // Game canvas (rendered as positioned divs)
    element.el(
      "div",
      [
        element.attr("class", "pong-canvas"),
        element.attr(
          "style",
          "position:relative;width:"
            <> int.to_string(width)
            <> "px;height:"
            <> int.to_string(height)
            <> "px;background:#111;margin:0 auto;overflow:hidden",
        ),
      ],
      [
        // Center line
        element.el(
          "div",
          [
            element.attr(
              "style",
              "position:absolute;left:50%;top:0;width:2px;height:100%;background:#333;",
            ),
          ],
          [],
        ),
        // Left paddle
        render_rect(
          0,
          model.left_y - paddle_height / 2,
          paddle_width,
          paddle_height,
          "#4ecdc4",
        ),
        // Right paddle
        render_rect(
          width - paddle_width,
          model.right_y - paddle_height / 2,
          paddle_width,
          paddle_height,
          "#ff6b6b",
        ),
        // Ball
        render_rect(
          model.ball_x - ball_size / 2,
          model.ball_y - ball_size / 2,
          ball_size,
          ball_size,
          "#fff",
        ),
      ],
    ),
    // Controls
    element.el("div", [element.attr("class", "pong-controls")], [
      element.el("div", [element.attr("class", "pong-player")], [
        element.el("strong", [], [element.text("Player 1 (Left)")]),
        element.el(
          "button",
          [element.on("click", "left_up")],
          [element.text("Up")],
        ),
        element.el(
          "button",
          [element.on("click", "left_down")],
          [element.text("Down")],
        ),
      ]),
      element.el("div", [element.attr("class", "pong-center-controls")], [
        case model.running {
          True ->
            element.el(
              "button",
              [element.on("click", "pause")],
              [element.text("Pause")],
            )
          False ->
            element.el(
              "button",
              [element.on("click", "start")],
              [element.text("Start")],
            )
        },
      ]),
      element.el("div", [element.attr("class", "pong-player")], [
        element.el("strong", [], [element.text("Player 2 (Right)")]),
        element.el(
          "button",
          [element.on("click", "right_up")],
          [element.text("Up")],
        ),
        element.el(
          "button",
          [element.on("click", "right_down")],
          [element.text("Down")],
        ),
      ]),
    ]),
    element.el("p", [element.attr("class", "pong-info")], [
      element.text(
        "All game logic runs on the server. The browser just renders what the server sends.",
      ),
    ]),
  ])
}

/// Render a positioned rectangle.
fn render_rect(
  x: Int,
  y: Int,
  w: Int,
  h: Int,
  color: String,
) -> element.Node(Msg) {
  element.el(
    "div",
    [
      element.attr(
        "style",
        "position:absolute;left:"
          <> int.to_string(x)
          <> "px;top:"
          <> int.to_string(y)
          <> "px;width:"
          <> int.to_string(w)
          <> "px;height:"
          <> int.to_string(h)
          <> "px;background:"
          <> color,
      ),
    ],
    [],
  )
}

/// Decode client events.
pub fn decode_event(
  _name: String,
  handler_id: String,
  _data: String,
  _path: String,
) -> Result(Msg, error.BeaconError) {
  case handler_id {
    "left_up" -> Ok(LeftUp)
    "left_down" -> Ok(LeftDown)
    "right_up" -> Ok(RightUp)
    "right_down" -> Ok(RightDown)
    "start" -> Ok(StartGame)
    "pause" -> Ok(PauseGame)
    _ -> Error(error.RuntimeError(reason: "Unknown handler: " <> handler_id))
  }
}
