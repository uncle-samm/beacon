# Chat

Multi-room chat with presence tracking and typing indicators.

## Features

- Multiple rooms (general, random, help) with dynamic PubSub subscriptions
- Username login and per-room presence tracking
- Typing indicators via ephemeral PubSub notifications
- Shared message store -- messages persist across sessions

## Run

```bash
cd examples/chat
gleam run
```

Open http://localhost:8080 -- enter a name, switch rooms, and chat across multiple tabs.
