# Route Server Workspace

Focused example for route mini-apps with private route-local server state.

It exercises:

- Explicitly imported route modules with their own `Model`, `Msg`, and `view`
- Route-local `Server`, `init_server`, and `update_server`
- Root `Server state` embedding each route server value privately
- Generated client bundles that strip route server secrets before JS compilation

```sh
cd examples/route_server_workspace
gleam run -m main
```

Open http://localhost:8080.
