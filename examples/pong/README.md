# Pong

Two-player Pong with all game logic running on the server.

## Features

- Server-side game loop via `effect.background` at ~60fps
- Paddle controls for two players (button-based)
- Ball physics with wall bouncing and paddle collision
- Score tracking with automatic ball reset on point

## Run

```bash
cd examples/pong
gleam run
```

Open http://localhost:8080 -- click Start, then use the Up/Down buttons for P1 and P2.
