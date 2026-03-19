# Collaborative Canvas

Multi-user drawing canvas with real-time sync across tabs.

## Features

- Mouse events (mousedown, mousemove, mouseup) for freehand drawing
- Local state for instant drawing, shared store for multi-user sync
- SVG rendering of strokes with color picker
- PubSub notifications when other users draw

## Run

```bash
cd examples/canvas
gleam run
```

Open http://localhost:8080 in multiple tabs -- draw in one tab and see strokes appear in the other.
