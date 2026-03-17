/// Multiplayer Snake — demonstrates:
/// - Server-push via effect.every() (game tick at ~150ms)
/// - Arrow key input (on_keydown)
/// - Shared store for game state (all players see same board)
/// - Per-connection state (each player has their own snake)
/// - Collision detection (walls, self)

import beacon
import beacon/effect
import beacon/html
import beacon/store
import gleam/int
import gleam/list
import gleam/string

// --- Types ---

pub type Point {
  Point(x: Int, y: Int)
}

pub type Direction {
  Up
  Down
  Left
  Right
}

pub type GameState {
  Playing
  GameOver
}

pub type Model {
  Model(
    snake: List(Point),
    direction: Direction,
    food: Point,
    score: Int,
    game_state: GameState,
    grid_width: Int,
    grid_height: Int,
    player_name: String,
    name_input: String,
    has_name: Bool,
  )
}

pub type Msg {
  Tick
  ChangeDirection(Direction)
  RestartGame
  UpdateNameInput(String)
  SetName
  HighScoreUpdated
}

const grid_w = 20

const grid_h = 15

const cell_size = 25

// --- Init ---

pub fn init() -> Model {
  Model(
    snake: [Point(x: 10, y: 7)],
    direction: Right,
    food: Point(x: 15, y: 7),
    score: 0,
    game_state: Playing,
    grid_width: grid_w,
    grid_height: grid_h,
    player_name: "",
    name_input: "",
    has_name: False,
  )
}

// --- Update ---

pub fn make_update(
  high_scores: store.ListStore(String),
) -> fn(Model, Msg) -> #(Model, effect.Effect(Msg)) {
  fn(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
    case msg {
      Tick -> {
        case model.game_state {
          GameOver -> #(model, effect.none())
          Playing -> {
            let new_model = advance_snake(model, high_scores)
            #(new_model, effect.none())
          }
        }
      }

      ChangeDirection(dir) -> {
        // Prevent 180-degree turns
        let valid = case model.direction, dir {
          Up, Down | Down, Up | Left, Right | Right, Left -> False
          _, _ -> True
        }
        case valid {
          True -> #(Model(..model, direction: dir), effect.none())
          False -> #(model, effect.none())
        }
      }

      RestartGame -> {
        let new_food = random_food(model.snake)
        #(
          Model(
            ..model,
            snake: [Point(x: 10, y: 7)],
            direction: Right,
            food: new_food,
            score: 0,
            game_state: Playing,
          ),
          effect.every(150, fn() { Tick }),
        )
      }

      UpdateNameInput(text) -> #(
        Model(..model, name_input: text),
        effect.none(),
      )

      SetName -> {
        let name = string.trim(model.name_input)
        case string.is_empty(name) {
          True -> #(model, effect.none())
          False -> #(
            Model(..model, player_name: name, has_name: True),
            effect.every(150, fn() { Tick }),
          )
        }
      }

      HighScoreUpdated -> #(model, effect.none())
    }
  }
}

fn advance_snake(
  model: Model,
  high_scores: store.ListStore(String),
) -> Model {
  let assert [head, ..] = model.snake
  let new_head = case model.direction {
    Up -> Point(x: head.x, y: head.y - 1)
    Down -> Point(x: head.x, y: head.y + 1)
    Left -> Point(x: head.x - 1, y: head.y)
    Right -> Point(x: head.x + 1, y: head.y)
  }

  // Wall collision
  case
    new_head.x < 0
    || new_head.x >= model.grid_width
    || new_head.y < 0
    || new_head.y >= model.grid_height
  {
    True -> {
      // Record high score
      let entry =
        model.player_name
        <> ": "
        <> int.to_string(model.score)
      store.append(high_scores, "scores", entry)
      Model(..model, game_state: GameOver)
    }
    False -> {
      // Self collision
      case list.contains(model.snake, new_head) {
        True -> {
          let entry =
            model.player_name
            <> ": "
            <> int.to_string(model.score)
          store.append(high_scores, "scores", entry)
          Model(..model, game_state: GameOver)
        }
        False -> {
          // Ate food?
          let ate = new_head == model.food
          let new_snake = case ate {
            True -> [new_head, ..model.snake]
            False -> [new_head, ..drop_last(model.snake)]
          }
          let new_score = case ate {
            True -> model.score + 10
            False -> model.score
          }
          let new_food = case ate {
            True -> random_food(new_snake)
            False -> model.food
          }
          Model(
            ..model,
            snake: new_snake,
            food: new_food,
            score: new_score,
          )
        }
      }
    }
  }
}

fn drop_last(items: List(a)) -> List(a) {
  case items {
    [] -> []
    [_] -> []
    [x, ..rest] -> [x, ..drop_last(rest)]
  }
}

fn random_food(snake: List(Point)) -> Point {
  let x = abs_int(unique_int()) % grid_w
  let y = abs_int(unique_int()) % grid_h
  let p = Point(x: x, y: y)
  case list.contains(snake, p) {
    True -> random_food(snake)
    False -> p
  }
}

// --- View ---

pub fn view(model: Model) -> beacon.Node(Msg) {
  case model.has_name {
    False -> view_name_entry(model)
    True -> view_game(model)
  }
}

fn view_name_entry(model: Model) -> beacon.Node(Msg) {
  html.div(
    [
      html.style(
        "font-family:system-ui;max-width:600px;margin:2rem auto;text-align:center",
      ),
    ],
    [
      html.h1([], [html.text("Multiplayer Snake")]),
      html.p([], [html.text("Enter your name:")]),
      html.div([html.style("display:flex;gap:8px;justify-content:center")], [
        html.input([
          html.type_("text"),
          html.placeholder("Your name..."),
          html.value(model.name_input),
          beacon.on_input(UpdateNameInput),
        ]),
        html.button([beacon.on_click(SetName)], [html.text("Play")]),
      ]),
    ],
  )
}

fn view_game(model: Model) -> beacon.Node(Msg) {
  let w = int.to_string(grid_w * cell_size)
  let h = int.to_string(grid_h * cell_size)
  html.div(
    [
      html.style("font-family:system-ui;max-width:600px;margin:2rem auto"),
      beacon.on_keydown(fn(key) {
        case key {
          "ArrowUp" -> ChangeDirection(Up)
          "ArrowDown" -> ChangeDirection(Down)
          "ArrowLeft" -> ChangeDirection(Left)
          "ArrowRight" -> ChangeDirection(Right)
          _ -> Tick
        }
      }),
      html.attribute("tabindex", "0"),
    ],
    [
      html.h1([], [html.text("Snake — " <> model.player_name)]),
      html.p([], [
        html.text(
          "Score: "
          <> int.to_string(model.score)
          <> " | Use arrow keys",
        ),
      ]),
      // Game board
      html.element(
        "svg",
        [
          html.attribute("viewBox", "0 0 " <> w <> " " <> h),
          html.attribute("width", w),
          html.attribute("height", h),
          html.style(
            "border:2px solid #333;border-radius:4px;background:#1a1a2e;display:block",
          ),
        ],
        list.flatten([
          // Food
          [render_cell(model.food, "#ff4444", cell_size)],
          // Snake
          list.index_map(model.snake, fn(p, i) {
            let color = case i {
              0 -> "#44ff44"
              _ -> "#22cc22"
            }
            render_cell(p, color, cell_size)
          }),
          // Game over overlay
          case model.game_state {
            GameOver -> [
              html.element(
                "text",
                [
                  html.attribute(
                    "x",
                    int.to_string(grid_w * cell_size / 2),
                  ),
                  html.attribute(
                    "y",
                    int.to_string(grid_h * cell_size / 2),
                  ),
                  html.attribute("text-anchor", "middle"),
                  html.attribute("fill", "white"),
                  html.attribute("font-size", "32"),
                ],
                [html.text("GAME OVER")],
              ),
            ]
            Playing -> []
          },
        ]),
      ),
      case model.game_state {
        GameOver ->
          html.button(
            [
              beacon.on_click(RestartGame),
              html.style("margin-top:1rem;padding:8px 16px;font-size:16px"),
            ],
            [html.text("Play Again")],
          )
        Playing -> html.text("")
      },
    ],
  )
}

fn render_cell(p: Point, color: String, size: Int) -> beacon.Node(Msg) {
  html.element(
    "rect",
    [
      html.attribute("x", int.to_string(p.x * size + 1)),
      html.attribute("y", int.to_string(p.y * size + 1)),
      html.attribute("width", int.to_string(size - 2)),
      html.attribute("height", int.to_string(size - 2)),
      html.attribute("fill", color),
      html.attribute("rx", "3"),
    ],
    [],
  )
}

// --- Start ---

pub fn start() {
  let high_scores = store.new_list("snake_scores")

  beacon.app_with_effects(
    fn() { #(init(), effect.none()) },
    make_update(high_scores),
    view,
  )
  |> beacon.title("Multiplayer Snake")
  |> beacon.subscriptions(fn(_model) { ["store:snake_scores"] })
  |> beacon.on_notify(fn(_topic) { HighScoreUpdated })
  |> beacon.start(8080)
}

@external(erlang, "erlang", "unique_integer")
fn unique_int() -> Int

@external(erlang, "erlang", "abs")
fn abs_int(n: Int) -> Int
