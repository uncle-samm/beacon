/// Pong — demonstrates:
/// - app_with_effects for game tick loop
/// - effect.background for server-side game loop
/// - All game logic runs on the server

import beacon
import beacon/effect
import beacon/html
import gleam/int

const width = 600

const height = 400

const paddle_h = 80

const paddle_w = 10

const paddle_speed = 8

const ball_size = 10

pub type Model {
  Model(
    left_y: Int,
    right_y: Int,
    ball_x: Int,
    ball_y: Int,
    ball_dx: Int,
    ball_dy: Int,
    left_score: Int,
    right_score: Int,
    running: Bool,
  )
}

pub type Msg {
  LeftUp
  LeftDown
  RightUp
  RightDown
  Tick
  StartGame
  PauseGame
}

pub fn init() -> #(Model, effect.Effect(Msg)) {
  #(
    Model(
      left_y: height / 2,
      right_y: height / 2,
      ball_x: width / 2,
      ball_y: height / 2,
      ball_dx: 4,
      ball_dy: 2,
      left_score: 0,
      right_score: 0,
      running: False,
    ),
    effect.none(),
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    LeftUp -> #(
      Model(
        ..model,
        left_y: int.max(paddle_h / 2, model.left_y - paddle_speed),
      ),
      effect.none(),
    )
    LeftDown -> #(
      Model(
        ..model,
        left_y: int.min(height - paddle_h / 2, model.left_y + paddle_speed),
      ),
      effect.none(),
    )
    RightUp -> #(
      Model(
        ..model,
        right_y: int.max(paddle_h / 2, model.right_y - paddle_speed),
      ),
      effect.none(),
    )
    RightDown -> #(
      Model(
        ..model,
        right_y: int.min(
          height - paddle_h / 2,
          model.right_y + paddle_speed,
        ),
      ),
      effect.none(),
    )
    StartGame -> {
      let m =
        Model(
          ..model,
          running: True,
          ball_x: width / 2,
          ball_y: height / 2,
          ball_dx: 4,
          ball_dy: 2,
        )
      #(m, tick_effect())
    }
    PauseGame -> #(Model(..model, running: False), effect.none())
    Tick ->
      case model.running {
        False -> #(model, effect.none())
        True -> #(advance_ball(model), tick_effect())
      }
  }
}

fn tick_effect() -> effect.Effect(Msg) {
  effect.background(fn(dispatch) {
    sleep(16)
    dispatch(Tick)
  })
}

fn advance_ball(model: Model) -> Model {
  let new_x = model.ball_x + model.ball_dx
  let new_y = model.ball_y + model.ball_dy
  let new_dy = case new_y <= ball_size || new_y >= height - ball_size {
    True -> -model.ball_dy
    False -> model.ball_dy
  }
  let new_y = int.clamp(new_y, ball_size, height - ball_size)
  let #(dx, nx) = case
    new_x <= paddle_w + ball_size
    && new_y >= model.left_y - paddle_h / 2
    && new_y <= model.left_y + paddle_h / 2
  {
    True -> #(int.absolute_value(model.ball_dx), paddle_w + ball_size + 1)
    False -> #(model.ball_dx, new_x)
  }
  let #(dx, nx) = case
    nx >= width - paddle_w - ball_size
    && new_y >= model.right_y - paddle_h / 2
    && new_y <= model.right_y + paddle_h / 2
  {
    True -> #(-int.absolute_value(dx), width - paddle_w - ball_size - 1)
    False -> #(dx, nx)
  }
  case nx {
    x if x <= 0 ->
      Model(
        ..model,
        right_score: model.right_score + 1,
        ball_x: width / 2,
        ball_y: height / 2,
        ball_dx: 4,
        ball_dy: 2,
      )
    x if x >= width ->
      Model(
        ..model,
        left_score: model.left_score + 1,
        ball_x: width / 2,
        ball_y: height / 2,
        ball_dx: -4,
        ball_dy: 2,
      )
    _ ->
      Model(
        ..model,
        ball_x: nx,
        ball_y: new_y,
        ball_dx: dx,
        ball_dy: new_dy,
      )
  }
}

@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.div([html.class("pong-game")], [
    html.h1([], [html.text("Beacon Pong")]),
    html.div([html.class("pong-score")], [
      html.text(
        int.to_string(model.left_score)
        <> " - "
        <> int.to_string(model.right_score),
      ),
    ]),
    html.div(
      [
        html.style(
          "position:relative;width:"
          <> int.to_string(width)
          <> "px;height:"
          <> int.to_string(height)
          <> "px;background:#111;margin:0 auto;overflow:hidden",
        ),
      ],
      [
        rect(
          0,
          model.left_y - paddle_h / 2,
          paddle_w,
          paddle_h,
          "#4ecdc4",
        ),
        rect(
          width - paddle_w,
          model.right_y - paddle_h / 2,
          paddle_w,
          paddle_h,
          "#ff6b6b",
        ),
        rect(
          model.ball_x - ball_size / 2,
          model.ball_y - ball_size / 2,
          ball_size,
          ball_size,
          "#fff",
        ),
      ],
    ),
    html.div([html.class("pong-controls")], [
      html.div([], [
        html.strong([], [html.text("P1")]),
        html.button([beacon.on_click(LeftUp)], [html.text("Up")]),
        html.button([beacon.on_click(LeftDown)], [html.text("Down")]),
      ]),
      html.div([], [
        case model.running {
          True ->
            html.button([beacon.on_click(PauseGame)], [html.text("Pause")])
          False ->
            html.button([beacon.on_click(StartGame)], [html.text("Start")])
        },
      ]),
      html.div([], [
        html.strong([], [html.text("P2")]),
        html.button([beacon.on_click(RightUp)], [html.text("Up")]),
        html.button([beacon.on_click(RightDown)], [html.text("Down")]),
      ]),
    ]),
    html.p([], [html.text("All game logic runs on the server.")]),
  ])
}

fn rect(x: Int, y: Int, w: Int, h: Int, color: String) -> beacon.Node(Msg) {
  html.div(
    [
      html.style(
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
