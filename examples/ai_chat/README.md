# AI Chat

Real-time chat with deterministic server-side streaming responses.

## Features

- Character-by-character streaming with smooth typing effect
- Multi-turn conversation with full history
- Async server work via `effect.from` spawning background processes
- Input disabled while streaming
- No API key or external service dependency; suitable for browser conformance CI

## Run

```bash
cd examples/ai_chat
gleam run
```

Open http://localhost:8080 -- type a message and watch the server response stream character-by-character.
