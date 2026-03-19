# AI Chat

Real-time AI chat with streaming responses powered by Claude via OpenRouter.

## Features

- Character-by-character streaming with smooth typing effect
- Multi-turn conversation with full history
- Async AI calls via `effect.from` spawning background processes
- Input disabled while streaming

## Run

```bash
export OPENROUTER_API_KEY=your-key
cd examples/ai_chat
gleam run
```

Open http://localhost:8080 -- type a message and watch the AI response stream in character-by-character.
