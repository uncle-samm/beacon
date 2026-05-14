/// Pong — demonstrates:
/// - pure update with on_update for the server-side game loop
/// - effect.background for scheduled ticks
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

pub fn update(
  model: Model,
  _local: Nil,
  _server: Nil,
  msg: Msg,
) -> #(Model, Nil, Nil) {
  let model = case msg {
    LeftUp ->
      Model(..model, left_y: int.max(paddle_h / 2, model.left_y - paddle_speed))
    LeftDown ->
      Model(
        ..model,
        left_y: int.min(height - paddle_h / 2, model.left_y + paddle_speed),
      )
    RightUp ->
      Model(
        ..model,
        right_y: int.max(paddle_h / 2, model.right_y - paddle_speed),
      )
    RightDown ->
      Model(
        ..model,
        right_y: int.min(height - paddle_h / 2, model.right_y + paddle_speed),
      )
    StartGame -> {
      Model(
        ..model,
        running: True,
        ball_x: width / 2,
        ball_y: height / 2,
        ball_dx: 4,
        ball_dy: 2,
      )
    }
    PauseGame -> Model(..model, running: False)
    Tick ->
      case model.running {
        False -> model
        True -> advance_ball(model)
      }
  }
  #(model, Nil, Nil)
}

fn after_update(state: #(Model, Nil, Nil), msg: Msg) -> effect.Effect(Msg) {
  let model = state.0
  case msg {
    StartGame -> tick_effect()
    Tick ->
      case model.running {
        True -> tick_effect()
        False -> effect.none()
      }
    _ -> effect.none()
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
    _ -> Model(..model, ball_x: nx, ball_y: new_y, ball_dx: dx, ball_dy: new_dy)
  }
}

@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil

pub fn view(model: Model, _local: Nil) -> beacon.Node(Msg) {
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
        rect(0, model.left_y - paddle_h / 2, paddle_w, paddle_h, "#4ecdc4"),
        rect(
          width - paddle_w,
          model.right_y - paddle_h / 2,
          paddle_w,
          paddle_h,
          "#ff6b6b",
        ),
        ball_rect(
          model.ball_x - ball_size / 2,
          model.ball_y - ball_size / 2,
          ball_size,
          ball_size,
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

pub fn main() {
  beacon.app(init, beacon.no_local, beacon.no_server, update, view)
  |> beacon.title("Beacon Pong")
  |> beacon.on_update(after_update)
  |> beacon.start(8080)
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

fn ball_rect(x: Int, y: Int, w: Int, h: Int) -> beacon.Node(Msg) {
  html.div(
    [
      html.attribute("data-testid", "pong-ball"),
      html.style(
        "position:absolute;left:"
        <> int.to_string(x)
        <> "px;top:"
        <> int.to_string(y)
        <> "px;width:"
        <> int.to_string(w)
        <> "px;height:"
        <> int.to_string(h)
        <> "px;background:#fff",
      ),
    ],
    [],
  )
}
