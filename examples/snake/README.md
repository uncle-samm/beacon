# Snake

Classic snake game with arrow key controls and shared high scores.

## Features

- Server-push game tick via `effect.every(150ms)`
- Arrow key input with `beacon.on_keydown`
- Collision detection (walls and self)
- Shared high score store across all players

## Run

```bash
cd examples/snake
gleam run
```

Open http://localhost:8080 -- enter your name, then use arrow keys to control the snake.
